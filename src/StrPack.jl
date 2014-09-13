module StrPack

export @struct
export pack, unpack!, unpack, sizeof
export DataAlign
export align_default, align_packed, align_packmax, align_structpack, align_table
export align_x86_pc_linux_gnu, align_native
export show_struct_layout

using Base.Meta

import Base.read, Base.write
import Base.isequal

bswap(c::Char) = identity(c) # white lie which won't work for multibyte characters in UTF-16 or UTF-32

# Represents a particular way of adding bytes to maintain certain alignments
immutable DataAlign
    ttable::Dict
    # default::(Type -> Integer); used for bits types not in ttable
    default::Function
    # aggregate::(Vector{Type} -> Integer); used for composite types not in ttable
    aggregate::Function
end
DataAlign(def::Function, agg::Function) = DataAlign((Type=>Integer)[], def, agg)

immutable Struct
    asize::Dict
    bsize::Dict
    strategy::DataAlign
    endianness::Symbol
end

const STRUCT_REGISTRY = Dict{Type, Struct}()

macro struct(xpr...)
    (typname, typdef, asize, bsize) = extract_annotations(xpr[1])
    if length(xpr) > 3
        error("too many arguments supplied to @struct")
    end
    if length(xpr) > 2
        if isexpr(xpr[3], :quote) && haskey(endianness_converters, eval(xpr[3]))
            endianness = xpr[3]
        else
            error("$(string(xpr[3])) is not a valid endianness")
        end
        alignment = xpr[2]
    elseif length(xpr) > 1
        if isexpr(xpr[2], :quote) && haskey(endianness_converters, eval(xpr[2]))
            endianness = xpr[2]
            alignment = :(align_default)
        else
            alignment = xpr[2]
            endianness = :(:NativeEndian)
        end
    else
        alignment = :(align_default)
        endianness = :(:NativeEndian)
    end
    new_struct = :(Struct($asize, $bsize, $alignment, $endianness))

    quote
        $(esc(typdef))
        STRUCT_REGISTRY[$(esc(typname))] = $new_struct
        const fisequal = isequal
        fisequal(a::$(esc(typname)), b::$(esc(typname))) = begin
            for name in $(esc(typname)).names
                if !isequal(getfield(a, name), getfield(b, name))
                    return false
                end
            end
            true
        end
        # I can get rid of this by testing mutability from the AST
        eval(StrPack, gen_unpack($(esc(typname)), $asize))
    end
end

# hmm...AST selectors could be useful
function extract_annotations(exprIn)
    asizes = Expr[]
    bsizes = Expr[]
    typname = nothing
    fieldnames = Symbol[]
    if isexpr(exprIn, :type)
        if isa(exprIn.args[2],Symbol)
            typname = exprIn.args[2]
        elseif isexpr(exprIn.args[2],:<:)
            typname = exprIn.args[2].args[1]
        else
            error("Unable to extract type name!")
        end
        mutable = exprIn.args[1]
        for field_xpr in exprIn.args[3].args
            if isexpr(field_xpr, :(::))
                # first get and unwrap array size
                if isexpr(field_xpr.args[2], :call)
                    push!(asizes, quot((field_xpr.args[1], Any[field_xpr.args[2].args[2:end]...])))
                    field_xpr.args[2] = field_xpr.args[2].args[1]

                end
                # then get and unwrap bit width
                if isexpr(field_xpr.args[2], :ref)
                    push!(bsizes, quot((field_xpr.args[1], field_xpr.args[2].args[2])))
                    field_xpr.args[2] = field_xpr.args[2].args[1]
                end
                push!(fieldnames, field_xpr.args[1])
            end
        end
        # generate the default constructor and a stream constructor
        push!(exprIn.args[3].args, :($typname($(fieldnames...)) = new($(fieldnames...))))
        if mutable
            push!(exprIn.args[3].args, :($typname(ios::IO) = unpack!(new(), ios)
        else
            push!(exprIn.args[3].args, :($typname(ios::IO) = unpack(ios, $typname)))
        end
    else
        error("only type definitions can be supplied to @struct")
    end
    asize = !isempty(asizes) ? :(Dict([$(asizes...)])) : :(Dict())
    bsize = !isempty(bsizes) ? :(Dict([$(bsizes...)])) : :(Dict())
    (typname, exprIn, asize, bsize)
end

endianness_converters = {
    :BigEndian => (hton, ntoh),
    :LittleEndian => (htol, ltoh),
    :NativeEndian => (identity, identity),
    }

# A byte of padding
bitstype 8 PadByte
write(s::IO, x::PadByte) = write(s, 0x00)
read(s::IO, ::Type{PadByte}) = read(s, Uint8)

function isbitsequivalent{T}(::Type{T})
    if isbits(T) || T <: String && !T.abstract
        return true
    elseif isempty(T.names)
        return false
    end
    # TODO AbstractArray inspect element instead
    for S in T.types
        if S <: AbstractArray
            S = eltype(S)
        end
        if !isbitsequivalent(S)
            return false
        end
    end
    true
end

function chktype{T}(::Type{T})
    if isempty(T.names)
        error("Type $T is not an aggregate type.")
    end
    if !isbitsequivalent(T)
        error("Type $T is not bits-equivalent.")
    end
end

function gen_unpack(T, asize)
    chktype(T)
    exprs = Expr[]
    # we need the next two to manage gensyms and backrefs for immutables
    tmpnames = Symbol[]
    tmpname_refs = Dict{Symbol, Symbol}()
    push!(exprs, quote
        tgtendianness = endianness_converters[endianness][2]
        offset = 0
    end)
    for (typ, name) in zip(T.types, T.names)
        dims = copy(get(asize, name, 1))
        if T.mutable
            dst = :(dst.$name)
        else
            dst = gensym(string(name))
            push!(tmpnames, dst)
            tmpname_refs[name] = dst
        end
        for (idx, dim) in enumerate(dims)
            if isa(dim, Symbol)
                dims[idx] = T.mutable ? :(dst.$dim) : :($(tmpname_refs[dim]))
            end
        end
        intyp = (typ <: AbstractArray) ? eltype(typ) : typ
        push!(exprs, quote
            pad = pad_next(offset, $intyp, strategy)
            skip(inp, pad)
            offset += pad
        end)
        if intyp <: String
            push!(exprs, quote
                $dst = rstrip(convert($typ, read(inp, Uint8, $(dims...))), ['\0'])
                offset += *($(dims...))
            end)
        elseif !isempty(intyp.names)
            if typ <: AbstractArray
                # we generate a unique symbol here to maintain type stability in the generated fn
                @gensym tmp
                push!(exprs, quote
                    $tmp = Array($intyp, $(dims...))
                    for i in 1:length($tmp)
                        ($tmp)[i] = unpack(inp, $intyp)
                    end
                    $dst = $tmp
                end)
            else
                push!(exprs, :($dst = unpack(inp, $intyp)))
            end
            push!(exprs, :(offset += calcsize($intyp)* *($(dims...))))
        else
            if typ <: AbstractArray
                push!(exprs, :($dst = map(tgtendianness, read(inp, $intyp, $(dims...)))))
            else
                push!(exprs, :($dst = tgtendianness(read(inp, $intyp))))
            end
            push!(exprs, :(offset += sizeof($intyp)* *($(dims...))))
        end
    end
    push!(exprs, :(skip(inp, pad_next(offset, $T, strategy))))

    if T.mutable
        fn = quote
            function unpack!(dst::$T, inp::IO, strategy::DataAlign, endianness::Symbol)
                $(exprs...)
                dst
            end
        end
    else
        fn = quote
            function unpack(inp::IO, ::Type{$T}, strategy::DataAlign, endianness::Symbol)
                $(exprs...)
                $T($(tmpnames...))
            end
        end
    end
    fn
end

function unpack{T}(in::IO, ::Type{T}, strategy::DataAlign, endianness::Symbol)
    unpack!(T(), in, strategy, endianness)
end

function unpack!{T}(dst::T, in::IO)
    reg = STRUCT_REGISTRY[T]
    unpack!(dst, in, reg.strategy, reg.endianness)
end

function unpack{T}(in::IO, ::Type{T}, endianness::Symbol)
    reg = STRUCT_REGISTRY[T]
    unpack(in, T, reg.strategy, endianness)
end
function unpack{T}(in::IO, ::Type{T})
    reg = STRUCT_REGISTRY[T]
    unpack(in, T, reg.strategy, reg.endianness)
end

function pack{T}(out::IO, struct::T, asize::Dict, strategy::DataAlign, endianness::Symbol)
    chktype(T)
    tgtendianness = endianness_converters[endianness][1]
    offset = 0
    for (typ, name) in zip(T.types, T.names)
        if typ <: AbstractArray
            typ = eltype(typ)
        end
        data = if typ <: String
            typ = Uint8
            convert(Array{Uint8}, struct.(name))
        else
            struct.(name)
        end

        offset += write(out, zeros(Uint8, pad_next(offset, typ, strategy)))
        # process backreferences
        dims = get(asize, name, 1)
        for (idx, dim) in enumerate(dims)
            if isa(dim, Symbol)
                dims[idx] = struct.(dim)
            end
        end
        numel = prod(dims)

        idx_end = numel > 1 ? min(numel, length(data)) : 1
        if !isempty(typ.names)
            if typeof(data) <: AbstractArray
                for i in 1:idx_end
                    offset += pack(out, data[i])
                end
                offset += write(out, zeros(Uint8, calcsize(typ)*(numel-idx_end)))
            else
                offset += pack(out, data)
            end
        else
            offset += if typeof(data) <: AbstractArray
                isempty(data) ? 0 : write(out, map(tgtendianness, data[1:idx_end]))
            else
                write(out, tgtendianness(data))
            end
            offset += write(out, zeros(typ, max(numel-idx_end, 0)))
        end
    end
    offset += write(out, zeros(Uint8, pad_next(offset, T, strategy)))
end
function pack{T}(out::IO, struct::T, endianness::Symbol)
    chktype(T)
    reg = STRUCT_REGISTRY[T]
    pack(out, struct, reg.asize, reg.strategy, endianness)
end
function pack{T}(out::IO, struct::T)
    chktype(T)
    reg = STRUCT_REGISTRY[T]
    pack(out, struct, reg.asize, reg.strategy, reg.endianness)
end

# Convenience methods when you just want to use strings
macro withIOBuffer(iostr, ex)
    quote
        $iostr = IOBuffer()
        $ex
        $iostr
    end
end

pack{T}(struct::T, a::Dict, s::DataAlign, n::Symbol) = @withIOBuffer iostr pack(iostr, a, s, n)
pack{T}(struct::T) = @withIOBuffer iostr pack(iostr, struct)

unpack{T}(str::Union(String, Array{Uint8,1}), ::Type{T}) = unpack(IOBuffer(str), T)

## Alignment strategies and utility functions ##

# default alignment for bitstype T is nextpow2(sizeof(::Type{T}))
type_alignment_default{T<:AbstractArray}(::Type{T}) = type_alignment_default(eltype(T))
type_alignment_default{T<:String}(::Type{T}) = 1
type_alignment_default{T}(::Type{T}) = nextpow2(sizeof(T))

# default strategy
align_default = DataAlign(type_alignment_default, x -> maximum(map(type_alignment_default, x)))

# equivalent to __attribute__ (( __packed__ ))
align_packed = DataAlign(_ -> 1, _ -> 1)

# equivalent to #pragma pack(n)
align_packmax(da::DataAlign, n::Integer) = DataAlign(
    da.ttable,
    _ -> min(type_alignment_default(_), n),
    da.aggregate,
    )

# equivalent to __attribute__ (( align(n) ))
align_structpack(da::DataAlign, n::Integer) = DataAlign(
    da.ttable,
    da.default,
    _ -> n,
    )

# provide an alignment table
align_table(da::DataAlign, ttable::Dict) = DataAlign(
    merge(da.ttable, ttable),
    da.default,
    da.aggregate,
    )

# convenience forms using a default alignment
for fun in (:align_packmax, :align_structpack, :align_table)
    @eval ($fun)(arg) = ($fun)(align_default, arg)
end

# Specific architectures
align_x86_pc_linux_gnu = align_table(align_default,
    [
    Int64 => 4,
    Uint64 => 4,
    Float64 => 4,
    ])

# Get alignment for a given type
function alignment_for(strategy::DataAlign, T::Type)
    if haskey(strategy.ttable, T)
        strategy.ttable[T]
    elseif !isempty(T.names)
        strategy.aggregate(T.types)
    else
        strategy.default(T)
    end
end

function pad_next(offset, typ, strategy::DataAlign)
    align_to = alignment_for(strategy, typ)
    (align_to - offset % align_to) % align_to
end

function calcsize{T}(::Type{T}, asize::Dict, strategy::DataAlign)
    chktype(T)
    size = 0
    for (typ, name) in zip(T.types, T.names)
        dims = get(asize, name, 1)
        typ = if typ <: Array
            eltype(typ)
        elseif typ <: String
            Uint8
        else
            typ
        end
        size += pad_next(size, typ, strategy)
        size += if isbits(typ)
            prod(dims)*sizeof(typ)
        elseif !isempty(typ.names)
            prod(dims)*sizeof(Struct(typ))
        else
            error("Improper type $typ in struct.")
        end
    end
    size += pad_next(size, T, strategy)
    size
end
calcsize{T}(::Type{T}) = calcsize(T, STRUCT_REGISTRY[T].asize, STRUCT_REGISTRY[T].strategy)

function show_struct_layout{T}(::Type{T}, asize::Dict, strategy::DataAlign, width, bytesize)
    chktype(T)
    offset = 0
    for (typ, name) in zip(T.types, T.names)
        dims = get(asize, name, 1)
        intyp = if typ <: Array
            eltype(typ)
        elseif typ <: String
            Uint8
        else
            typ
        end
        padsize = pad_next(offset, intyp, strategy)
        offset = show_layout_format(PadByte, sizeof(PadByte), padsize, width, bytesize, offset)
        offset = show_layout_format(typ, sizeof(intyp), dims, width, bytesize, offset)
    end
    padsize = pad_next(offset, T, strategy)
    offset = show_layout_format(PadByte, sizeof(PadByte), padsize, width, bytesize, offset)
    if offset % width != 0
        println()
    end
end
show_struct_layout{T}(::Type{T}) = show_struct_layout(T, STRUCT_REGISTRY[T].asize, STRUCT_REGISTRY[T].strategy, 8, 10)
show_struct_layout{T}(::Type{T}, width::Integer, bytesize::Integer) = show_struct_layout(T, STRUCT_REGISTRY[T].asize, STRUCT_REGISTRY[T].strategy, width, bytesize)
# show_struct_layout(T::Type, asize::Dict, strategy::DataAlign, width) = show_struct_layout(T, strategy, width, 10)

function show_layout_format(typ, typsize, dims, width, bytesize, offset)
    for i in 1:prod(dims)
        tstr = string(typ)[1:min(typsize*bytesize-2, end)]
        str = "[" * tstr * "-"^(bytesize*typsize-2-length(tstr)) * "]"
        typsize_i = typsize
        while !isempty(str)
            if offset % width == 0
                @printf("0x%04X ", offset)
            end
            len_prn = min(width - (offset % width), typsize_i)
            nprint = bytesize*len_prn
            print(str[1:nprint])
            str = str[nprint+1:end]
            typsize_i -= len_prn
            offset += len_prn
            if offset % width == 0
                println()
            end
        end
    end
    offset
end

## Native layout ##
align_native = align_table(align_default, let
    i8a, i16a, i32a, i64a, f32a, f64a = Array(Uint, 1), Array(Uint, 1), Array(Uint, 1), Array(Uint, 1), Array(Uint, 1), Array(Uint, 1)

    ccall("jl_native_alignment", Void,
          (Ptr{Uint}, Ptr{Uint}, Ptr{Uint}, Ptr{Uint}, Ptr{Uint}, Ptr{Uint}),
          i8a, i16a, i32a, i64a, f32a, f64a)

    [
     Int8 => i8a[1],
     Uint8 => i8a[1],
     Int16 => i16a[1],
     Uint16 => i16a[1],
     Int32 => i32a[1],
     Uint32 => i32a[1],
     Int64 => i64a[1],
     Uint64 => i64a[1],
     Float32 => f32a[1],
     Float64 => f64a[1],
     ]
end)

end
