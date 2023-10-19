module DevOnly
import Serialization
import SHA

export @staticinclude, @devonly, isdevonly

const _force_runtime = Ref(false)

function isdevonly()
    if _force_runtime[]
        return false
    end
    return get(ENV, "JULIA_DEVONLY_COMPILE", "") == "1"
end

macro devonly(ex)
    if isdevonly()
        return esc(ex)
    else
        return esc(:nothing)
    end
end

macro staticinclude(file::String)
    targetfile = splitext(file)[1] * ".compiled.jl"
    dir = dirname(string(__source__.file))
    ex = if isdevonly()
        quote
            let
                local abs_srcfile = joinpath($dir, $file)
                local abs_targetfile = joinpath($dir, $targetfile)
                $__module__.include(abs_srcfile)
                $DevOnly.expand!($__module__, abs_srcfile, abs_targetfile)
            end
        end
    else
        :(include($targetfile))
    end
    esc(ex)
end

@static if isdefined(Meta, :parseall)
    const parseall_expr = Meta.parseall
else
    function parseall_expr(text::AbstractString; filename=nothing)
        return Meta.parse("begin; $text; end")
    end
end

function readast(filename)
    text = open(filename) do f
        read(f, String)
    end
    parseall_expr(text; filename=filename)
end

function toliteral(xs::Vector{UInt8})
    buf = IOBuffer()
    write(buf, 'b')
    write(buf, '"')
    for x in xs
        write(buf, "\\x", string(x, base=16, pad=2))
    end
    write(buf, '"')
    return String(take!(buf))
end

function with_runtime(f)
    st = _force_runtime[]
    try
        _force_runtime[] = true
        f()
    finally
        _force_runtime[] = st
    end
end

@noinline function expand!(ctx::Module, src::AbstractString, target::AbstractString)
    src_ast = readast(src)

    expanded_ast = with_runtime() do
        macroexpand(ctx, src_ast; recursive=true)
    end

    buf = IOBuffer()
    Serialization.serialize(buf, expanded_ast)
    data = take!(buf)
    sign_data = SHA.sha224(data)

    open(target, "w") do f
        write(f, """
# This file is automatically generated by DevOnly.jl
import Serialization
import SHA
let
    expected_sign = $(toliteral(sign_data))
    data = $(toliteral(data))
    sign_data = SHA.sha224(data)
    if sign_data != expected_sign
        error("The compiled data file", $(repr(target)), "is not verified. Please recompile it.")
    end
    buf = IOBuffer(data)
    Base.eval(@__MODULE__(), Serialization.deserialize(buf))
end
""")
    end
end

function __init__()
    _force_runtime[] = false
end

end