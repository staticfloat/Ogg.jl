using BinDeps
using Compat

@BinDeps.setup

libogg = library_dependency("libogg", aliases = ["libogg"])

@osx_only begin
  using Homebrew
  provides( Homebrew.HB, "libogg", libogg, os = :Darwin )
end

provides( AptGet, "libogg0", libogg )

@compat @BinDeps.install Dict(:libogg => :libogg)
