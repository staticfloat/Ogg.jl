module Ogg
using Ogg_jll
using FileIO
import Base: show, convert
export load, save, OggDecoder, OggEncoder

include("types.jl")
include("decoder.jl")
include("encoder.jl")

end # module
