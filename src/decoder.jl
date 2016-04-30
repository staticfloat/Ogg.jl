type OggDecoder
    sync_state::OggSyncState
    streams::Dict{Clong,OggStreamState}
    packets::Dict{Clong,Vector{Vector{UInt8}}}

    function OggDecoder()
        syncref = Ref{OggSyncState}(OggSyncState())
        status = ccall((:ogg_sync_init,libogg), Cint, (Ref{OggSyncState},), syncref)
        dec = new(syncref[], Dict{Cint,OggStreamState}(), Dict{Cint,Vector{Vector{UInt8}}}())
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

function ogg_stream_packetout(dec::OggDecoder, serial::Clong)
    if !haskey(dec.streams, serial)
        return nothing
    end
    streamref = Ref{OggStreamState}(dec.streams[serial])
    packetref = Ref{OggPacket}(OggPacket())
    status = ccall((:ogg_stream_packetout,libogg), Cint, (Ref{OggStreamState}, Ref{OggPacket}), streamref, packetref)
    dec.streams[serial] = streamref[]
    #println("ogg_stream_packetout(&os, $serial): $status")
    if status == 1
        return packetref[]
    else
        return nothing
    end
end


function decode_next_page(dec::OggDecoder, enc_io::IO; chunk_size::Integer = 4096)
    #println("decode_next_page(dec, enc_io; chunk_size=$chunk_size)")
    page = nothing

    # Load data in until we have a page to sync out
    while page == nothing
        page = ogg_sync_pageout(dec)

        if page != nothing
            break
        elseif eof(enc_io)
            return nothing
        end

        # Load in up to `chunk_size` of data, unless the stream closes before that
        buffer = ogg_sync_buffer(dec, chunk_size)
        bytes_read = readbytes!(enc_io, buffer, chunk_size)
        ogg_sync_wrote(dec, bytes_read)
    end

    # We've got a page, write it out into the proper stream
    ogg_stream_pagein(dec, page)
    return page
end

function decode_all_packets(dec::OggDecoder, serial::Clong)
    #println("decode_all_packets(dec, $serial)")
    packet = nothing

    packet = ogg_stream_packetout(dec, serial)
    while packet != nothing
        # Store packet into our data
        push!(dec.packets[serial], copy(pointer_to_array(packet.packet, packet.bytes)))

        # Have we hit the end of this stream?  If so, remove it and release its resources
        if packet.e_o_s == 1
            delete!(dec.streams, serial)
        end

        packet = ogg_stream_packetout(dec, serial)
    end
end

function decode_all(dec::OggDecoder, fio::IO)
    while true
        # Load in a page
        page = decode_next_page(dec, fio)

        # Try to decode packets for the serial that this page just gave us
        if page != nothing
            serial = ogg_page_serialno(page)
            decode_all_packets(dec, serial)
        else
            break
        end
    end

    # Then, at the end, drain each serial
    for serial in keys(dec.streams)
        decode_all_packets(dec, serial)
    end
    return dec
end

function decode_all(dec::OggDecoder, file_path::AbstractString)
    open(file_path) do fio
        return decode_all(dec, fio)
    end
end
