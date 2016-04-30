module Ogg
using Compat
import Base: show

const depfile = joinpath(dirname(@__FILE__), "..", "deps", "deps.jl")
if isfile(depfile)
    include(depfile)
else
    error("libogg not properly installed. Please run Pkg.build(\"Ogg\")")
end

include("types.jl")
include("decoder.jl")
include("encoder.jl")

end # module
