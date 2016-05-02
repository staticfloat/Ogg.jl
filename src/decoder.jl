type OggDecoder
    sync_state::OggSyncState
    streams::Dict{Clong,OggStreamState}
    packets::Dict{Clong,Vector{Vector{UInt8}}}

    function OggDecoder()
        syncref = Ref{OggSyncState}(OggSyncState())
        status = ccall((:ogg_sync_init,libogg), Cint, (Ref{OggSyncState},), syncref)
        dec = new(syncref[], Dict{Clong,OggStreamState}(), Dict{Clong,Vector{Vector{UInt8}}}())
        if status != 0
            error("ogg_sync_init() failed: This should never happen")
        end

        # This seems to be causing problems.  :(
        # finalizer(dec, x -> begin
        #     for serial in keys(x.streams)
        #         ogg_stream_destroy(x.streams[serial])
        #     end
        #     ogg_sync_destroy(x.sync_state)
        # end )

        return dec
    end
end

function show(io::IO, x::OggDecoder)
    num_streams = length(x.streams)
    if num_streams != 1
        write(io, "OggDecoder with $num_streams streams")
    else
        write(io, "OggDecoder with 1 stream")
    end
end

function ogg_sync_buffer(dec::OggDecoder, size)
    syncref = Ref{OggSyncState}(dec.sync_state)
    buffer = ccall((:ogg_sync_buffer,libogg), Ptr{UInt8}, (Ref{OggSyncState}, Clong), syncref, size)
    dec.sync_state = syncref[]
    if buffer == C_NULL
        error("ogg_sync_buffer() failed: returned buffer NULL")
    end
    return pointer_to_array(buffer, size)
end

function ogg_sync_wrote(dec::OggDecoder, size)
    syncref = Ref{OggSyncState}(dec.sync_state)
    status = ccall((:ogg_sync_wrote,libogg), Cint, (Ref{OggSyncState}, Clong), syncref, size)
    #println("ogg_sync_wrote(&os, $size): $status")
    dec.sync_state = syncref[]
    if status != 0
        error("ogg_sync_wrote() failed: error code $status")
    end
end

function ogg_sync_pageout(dec::OggDecoder)
    syncref = Ref{OggSyncState}(dec.sync_state)
    pageref = Ref{OggPage}(OggPage())
    status = ccall((:ogg_sync_pageout,libogg), Cint, (Ref{OggSyncState}, Ref{OggPage}), syncref, pageref)
    dec.sync_state = syncref[]
    #println("ogg_sync_pageout(&os, &op): $status")
    if status == 1
        return pageref[]
    else
        return nothing
    end
end

function ogg_page_serialno(page::OggPage)
    pageref = Ref{OggPage}(page)
    return Clong(ccall((:ogg_page_serialno,libogg), Cint, (Ref{OggPage},), pageref))
end


"""
Send a page in, return the serial number of the stream that we just decoded
"""
function ogg_stream_pagein(dec::OggDecoder, page::OggPage)
    serial = ogg_page_serialno(page)
    if !haskey(dec.streams, serial)
        #println("Creating new stream for serial $serial")
        streamref = Ref{OggStreamState}(OggStreamState())
        status = ccall((:ogg_stream_init,libogg), Cint, (Ref{OggStreamState}, Cint), streamref, serial)
        if status != 0
            error("ogg_stream_init() failed: Unknown failure")
        end
        dec.streams[serial] = streamref[]

        # Also initialize dec.packets for this serial
        dec.packets[serial] = Vector{Vector{UInt8}}()
    end

    streamref = Ref{OggStreamState}(dec.streams[serial])
    pageref = Ref{OggPage}(page)
    status = ccall((:ogg_stream_pagein,libogg), Cint, (Ref{OggStreamState}, Ref{OggPage}), streamref, pageref)
    dec.streams[serial] = streamref[]
    if status != 0
        error("ogg_stream_pagein() failed: Unknown failure")
    end
    return serial
end

function ogg_stream_packetout(dec::OggDecoder, serial::Clong; retry::Bool = false)
    if !haskey(dec.streams, serial)
        return nothing
    end
    streamref = Ref{OggStreamState}(dec.streams[serial])
    packetref = Ref{OggPacket}(OggPacket())
    status = ccall((:ogg_stream_packetout,libogg), Cint, (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
    dec.streams[serial] = streamref[]
    if status == 1
        #println("Packet[$(packetref[].packetno)]: $(packetref[].granulepos)")
        return packetref[]
    else
        # Is our status -1?  That means we're desynchronized and should try again, at least once
        if status == -1 && !retry
            return ogg_stream_packetout(dec, serial; retry = true)
        end
        return nothing
    end
end

"""
File goes in, packets come out
"""
function decode_all_packets(dec::OggDecoder, enc_io::IO; chunk_size::Integer = 4096)
    # Load data in until we have a page to sync out
    while !eof(enc_io)
        page = ogg_sync_pageout(dec)
        while page != nothing
            ogg_stream_pagein(dec, page)
            page = ogg_sync_pageout(dec)
        end

        # Load in up to `chunk_size` of data, unless the stream closes before that
        buffer = ogg_sync_buffer(dec, chunk_size)
        bytes_read = readbytes!(enc_io, buffer, chunk_size)
        ogg_sync_wrote(dec, bytes_read)
    end

    # Do our last pageouts to get the last pages
    page = ogg_sync_pageout(dec)
    while page != nothing
        ogg_stream_pagein(dec, page)
        page = ogg_sync_pageout(dec)
    end

    # Now, decode all packets for these pages
    for serial in keys(dec.streams)
        packet = ogg_stream_packetout(dec, serial)
        while packet != nothing
            push!(dec.packets[serial], copy(pointer_to_array(packet.packet, packet.bytes)))

            if packet.e_o_s == 1
                delete!(dec.streams, serial)
            end

            packet = ogg_stream_packetout(dec, serial)
        end
    end

    return dec.packets
end

function load(fio::IO)
    dec = OggDecoder()
    return decode_all_packets(dec, fio)
end

function load(file_path::Union{File{format"OGG"},AbstractString})
    open(file_path) do fio
        return load(fio)
    end
end
