""" 
    read_symops_xyzt(sgnum::Integer, dim::Integer=3)

    Obtains the symmetry operations in xyzt format for a given space group
    number `sgnum` by reading from json files; see `get_symops` for additional
    details. Much faster than crawling; generally preferred.
"""
function read_symops_xyzt(sgnum::Integer, dim::Integer=3)
    if all(dim .!= [2,3]); error(DomainError(dim, "dim must be 2 or 3")); end
    if sgnum < 1 || dim == 3 && sgnum > 230 || dim == 2 && sgnum > 17; 
        error(DomainError(sgnum, "sgnum must be in range 1:17 in 2D and in 1:230 in 3D")) 
    end

    filepath = (@__DIR__)*"/../data/symops/"*string(dim)*"d/"*string(sgnum)*".json"
    symops_str = open(filepath) do io
        JSON2.read(io)
    end
    return symops_str
end

""" 
    get_symops(sgnum::Integer, dim::Integer=3; verbose::Bool=false) --> SpaceGroup

    Obtains the symmetry operations in xyzt and matrix format for a 
    given space group number (`= sgnum`). The symmetry operations are 
    specified relative to the conventional basis vector choices, i.e.
    not necessarily primitive. If desired, operations on a primitive
    unit cell can be generated by multiplying with an appropriate 
    transformation matrix.
    The default choices for basis vectors are specified in Bilbao as:
        - Unique axis b (cell choice 1) for space groups within the 
          monoclinic system.
        - Obverse triple hexagonal unit cell for R space groups.
        - Origin choice 2 - inversion center at (0,0,0) - for the 
          centrosymmetric space groups for which there are two origin
          choices, within the orthorhombic, tetragonal and cubic systems.
"""
function get_symops(sgnum::Integer, dim::Integer=3; verbose::Bool=false)
    if verbose; print(sgnum, "\n"); end
    sgops_str = read_symops_xyzt(sgnum, dim)
    symops =  SymOperation.(sgops_str)

    return SpaceGroup(sgnum, symops, dim)
end



function xyzt2matrix(s::String)
    ssub = split(s,",")
    dim = length(ssub)
    xyzt2matrix!(zeros(Float64, dim, dim+1), ssub)
end

function xyzt2matrix!(O::Matrix{Float64}, s::Union{T, Array{T}} where T<:AbstractString)
    if s isa AbstractString
        itr = split(s,",")
    elseif s isa Array
        itr = s
    end

    for (i,op) in enumerate(itr)
        # rotation/inversion/reflection part
        nextidx = 1
        while true
            idx = findnext(r"x|y|z", op, nextidx);
            if !isnothing(idx)
                opchar = op[idx]
                if     opchar == "x"; j = 1; 
                elseif opchar == "y"; j = 2;
                elseif opchar == "z"; j = 3; end
                
                if idx[1] == 1 || op[prevind(op, idx[1])] == '+'
                    O[i,j] = 1.0
                elseif op[prevind(op, idx[1])] == '-'
                    O[i,j] = -1.0
                end
                nextidx = nextind(op, idx[end])
            else
                break
            end
        end
        
        # nonsymmorphic part/fractional translation part
        nonsymmorph = op[nextidx:end]
        if !isempty(nonsymmorph)
            slashidx = findfirst(x->x=='/',nonsymmorph)
            num=nonsymmorph[1:prevind(nonsymmorph, slashidx)]
            den=nonsymmorph[nextind(nonsymmorph, slashidx):end]
            O[i,end] = parse(Int64, num)/parse(Int64, den)
        end
    end
        
    return O
end

signaschar(x::Number) = signbit(x) ? '-' : '+'
const idx2xyz = ['x', 'y', 'z']

function matrix2xyzt(O::Matrix{T}) where T<:Real
    dim = size(O,1)
    buf = IOBuffer()
    # rotation/inversion/reflection part
    for (i, row) in enumerate(eachrow(O))
        # rotation/inversion/reflection part
        firstchar = true
        for j = 1:dim
            if !iszero(row[j])
                if !firstchar || signbit(row[j])
                    write(buf, signaschar(row[j]))
                end
                write(buf, idx2xyz[j]) 
                firstchar = false
            end
        end

        # nonsymmorphic/fractional translation part
        if size(O,2) == dim+1 # for size(O) = dim×dim+1, interpret as a space-group operation and check for nonsymmorphic parts; otherwise, assume a point-group operation
            if !iszero(row[end])
                write(buf, signaschar(row[end]))
                t = rationalize(float(row[end]), tol=1e-2) # convert to "minimal" Rational fraction (within nearest 1e-2 neighborhood)
                write(buf, string(abs(numerator(t)), '/', denominator(t)))
            end
        end
        if i != dim; write(buf, ','); end
    end

    return String(take!(buf))
end


function stripnum(s)
    if occursin(' ', s) # if the operation "number" is included as part of s
        _,s = split(s, isspace; limit=2)
    end
    return String(s) # ensure we return a String, rather than possibly a SubString
end


# Implementation based on ITA Vol. A, Table 11.2.1.1, using the table (for 3D)
#      _______________________________________________
#     |_detW_\_trW_|_-3_|_-2 |_-1 |__0_|__1_|__2_|__3_|
#     |    1       |    |    |  2 |  3 |  4 |  6 |  1 |
#     |___-1_______|_-1_|_-6_|_-4_|_-3_|__m_|____|____|
#
# with the elements of the table giving the type of symmetry operation 
# in Hermann-Mauguin notation.
# TODO: So far, we only attempted for 3D.
function seitz(op::SymOperation)
    W = pg(op); w = translation(op)

    detW = det(W); detW′, detW = detW, round(Int64, detW) # det, then round & flip
    detW′ ≈ detW || throw(ArgumentError("det W must be an integer for a SymOperation {W|w}"))
    trW  = tr(W);  trW′,  trW  = trW, round(Int64, trW)   # tr, then round & flip
    trW′ ≈ trW || throw(ArgumentError("tr W must be an integer for a SymOperation {W|w}"))

    if detW == 1 # proper rotations
        # order of rotation
        if -1 ≤ trW ≤ 1 # 2-, 3-, or 4-fold rotation
            seitz_str = string(Char(0x33+trW)) # 0x33 (UInt8) corresponds to '3' in unicode and trW=0; then we move forward/backward by adding/subtracting trW
        elseif trW == 2 # 6-fold rotation
            seitz_str = "6"
        elseif trW == 3 # identity operation
            seitz_str = "1"
        else 
            throw_seitzerror(trW, detW)
        end
    elseif detW == -1 # rotoinversions
        # order of rotation
        if trW == -3    # inversion
            seitz_str = "-1"
        elseif trW == -2 # 6-fold rotoinversion
            seitz_str = "-6"
        elseif -1 ≤ trW ≤ 0 # 4- and 3-fold rotoinversion
            seitz_str = string('-', Char(0x33-trW)) # same as before, now we subtract/add to move forward/backward
        elseif trW == 1  # mirror
            seitz_str = "m"
        else
            throw_seitzerror(trW, detW)
        end
    end

    #=
        # axis of rotation 
        # solve for {W|w}²𝐱=𝐱 ⇔ {W²|Ww+w}𝐱=𝐱 ⇔ (W²-I)𝐱=-Ww-w; 𝐱 is the axis
        if -2 ≤ trW ≤ 0
            W′ = W^2; w′ = W*w.+w

            hom = vec(nullspace(W′))
            idx = findall(hom); 
            # TODO: will not work with diagonal axes...
            length(idx) > 1 && throw(ArgumentError("The axis of rotation cannot be found"))
            idx = first(idx)
            axis_char = idx == 1 ? 'x' : (idx == 2 ? 'y' : 'z')

            !iszero(w′[idx]) && throw(ArgumentError("The axis of rotation cannot be found"))
            keep=filter(x->x!=idx, 1:3)
            inhom = W′[[keep],[keep]]\w′[[keep]]
            if iszero(inhom) # axis is at origin
                axis_str = string(axis_char))
            else # axis is not at origin
                axis_str = string(axis_char))*
    =#
    
    if !iszero(w)
        return '{'*seitz_str*'|'*join(string.(w),',')*'}'
    else
        return seitz_str
    end
end
throw_seitzerror(trW, detW) = throw(ArgumentError("trW = $(trW) for detW = $(detW) is not a valid symmetry operation; see ITA Vol A, Table 11.2.1.1"))




"""
    issymmorph(sg::SpaceGroup) --> Bool

    Checks whether a given space group `sg` is symmorphic (true) or
    nonsymmorphic (false)
"""
issymmorph(sg::SpaceGroup) = all(issymmorph.(operations(sg)))

"""
    issymmorph(sg::SpaceGroup) --> Bool

    Checks whether a given space group `sgnum` is symmorphic (true) or
    nonsymmorphic (false)
"""
issymmorph(sgnum::Integer, dim::Integer=3) = issymmorph(get_symops(sgnum, dim; verbose=false))

# ----- GROUP ELEMENT COMPOSITION -----
""" 
    (∘)(op1::T, op2::T) where T<:SymOperation

    Compose two symmetry operations (of the ::SymOperation kind)
    using the composition rule (in Seitz notation)
        {W₁|w₁}{W₂|w₂} = {W₁*W₂|w₁+W₁*t₂}
    for symmetry operations opᵢ = {Wᵢ|wᵢ}. Returns another
    `SymOperation`, with nonsymmorphic parts in the range [0,1].
"""
(∘)(op1::T, op2::T) where T<:SymOperation = SymOperation(matrix(op1) ∘ matrix(op2))
function (∘)(op1::T, op2::T) where T<:Matrix{Float64}
    W′ = pg(op1)*pg(op2)
    w′ = mod.(translation(op1) .+ pg(op1)*translation(op2), 1.0)
    return [W′ w′]
end
const compose = ∘


""" 
    multtable(symops::T) where T<:Union{Vector{SymOperation}, SpaceGroup}

    Computes the multiplication table of a set of symmetry operations.
    A MultTable is returned, which contains symmetry operations 
    resulting from composition of `row ∘ col` operators; the table of 
    indices give the symmetry operators relative to the ordering of 
    `symops`.
"""
function multtable(symops::AbstractVector{SymOperation}; verbose::Bool=false)
    havewarned = false
    N = length(symops)
    indices = Matrix{Int64}(undef, N,N)
    for (row,oprow) in enumerate(symops)
        for (col,opcol) in enumerate(symops)
            op′ = matrix(oprow) ∘ matrix(opcol)
            match = findfirst(op′′ -> op′≈matrix(op′′), symops)
            if isnothing(match)
                if !havewarned
                    if verbose; @warn "The given operations do not form a group!"; end
                    havewarned = true
                end
                match = 0
            end
            @inbounds indices[row,col] = match
        end
    end
    return MultTable(symops, indices, !havewarned)
end
multtable(sg::SpaceGroup) = multtable(operations(sg))


checkmulttable(lgir::LGIrrep, αβγ=nothing; verbose::Bool=false) = checkmulttable(multtable(operations(lgir)), lgir, αβγ; verbose=verbose)
function checkmulttable(mt::MultTable, lgir::LGIrrep, αβγ=nothing; verbose::Bool=false)
    havewarned = false
    irs = irreps(lgir, αβγ)
    ops = operations(lgir)
    k = kvec(lgir)(αβγ)
    N = length(ops)
    mtindices = indices(mt)
    checked = trues(N, N)
    for (row,irrow) in enumerate(irs)
        for (col,ircol) in enumerate(irs)
            @inbounds mtidx = mtindices[row,col]
            if iszero(mtidx) && !havewarned
                @warn "Provided multtable is not a group; cannot compare with irreps"
                checked[row,col] = false
                havewarned = true
            end
            ir′ = irrow*ircol
            # --- If 𝐤 is on the BZ boundary and if the little group is nonsymmorphic ---
            # --- the representation could be a ray representation (see Inui, p. 89), ---
            # --- such that DᵢDⱼ = αᵢⱼᵏDₖ with a phase factor αᵢⱼᵏ = exp(i*𝐤⋅𝐭₀) where ---
            # --- 𝐭₀ is a lattice vector 𝐭₀ = τᵢ + βᵢτⱼ - τₖ, for symmetry operations  ---
            # --- {βᵢ|τᵢ}. To ensure we capture this, we include this phase here.     ---
            # --- See Inui et al. Eq. (5.29) for explanation.                         ---
            t₀ = translation(ops[row]) + pg(ops[row])*translation(ops[col]) - translation(ops[mtidx])
            ϕ =  2π*k'*t₀ # include factor of 2π here due to normalized bases
            match = ir′ ≈ exp(1im*ϕ)*irs[mtidx]           
            if !match
                checked[row,col] = false
                if !havewarned
                    if verbose
                        @info """Provided irreps do not match group multiplication table:
                                 First failure at (row,col) = ($(row),$(col));
                                 Expected idx = $(mtidx), got idx = $(findall(ir′′ -> ir′′≈ ir′, irs))"""
                    end
                    havewarned = true
                end
            end
        end
    end
    return checked
end


# ----- LITTLE GROUP OF 𝐤 -----
# A symmetry operation g acts on a wave vector as (𝐤′)ᵀ = 𝐤ᵀg⁻¹ since we 
# generically operate with g on functions f(𝐫) via gf(𝐫) = f(g⁻¹𝐫), such that 
# the operation on a plane wave creates exp(i𝐤⋅g⁻¹𝐫); invariant plane waves 
# then define the little group elements {g}ₖ associated with wave vector 𝐤. 
# The plane waves are evidently invariant if 𝐤ᵀg⁻¹ = 𝐤ᵀ, or since g⁻¹ = gᵀ 
# (orthogonal transformations), if (𝐤ᵀg⁻¹)ᵀ = 𝐤 = (g⁻¹)ᵀ𝐤 = g𝐤; corresponding
# to the requirement that 𝐤 = g𝐤). Because we have g and 𝐤 in different bases
# (in the direct {𝐑} and reciprocal {𝐆} bases, respectively), we have to take 
# a little extra care here. Consider each side of the equation 𝐤ᵀ = 𝐤ᵀg⁻¹, 
# originally written in Cartesian coordinates, and rewrite each Cartesian term
# through basis-transformation to a representation we know (w/ P(𝐗) denoting 
# a matrix with columns of 𝐗m that facilitates this transformation):
#   𝐤ᵀ = [P(𝐆)𝐤(𝐆)]ᵀ = 𝐤(𝐆)ᵀP(𝐆)ᵀ                    (1)
#   𝐤ᵀg⁻¹ = [P(𝐆)𝐤(𝐆)]ᵀ[P(𝐑)g(𝐑)P(𝐑)⁻¹]⁻¹
#         = 𝐤(𝐆)ᵀP(𝐆)ᵀ[P(𝐑)⁻¹]⁻¹g(𝐑)⁻¹P(𝐑)⁻¹
#         = 𝐤(𝐆)ᵀ2πg(𝐑)⁻¹P(𝐑)⁻¹                       (2)
# (1+2): 𝐤′(𝐆)ᵀP(𝐆)ᵀ = 𝐤(𝐆)ᵀ2πg(𝐑)⁻¹P(𝐑)⁻¹
#     ⇔ 𝐤′(𝐆)ᵀ = 𝐤(𝐆)ᵀ2πg(𝐑)⁻¹P(𝐑)⁻¹[P(𝐆)ᵀ]⁻¹ 
#               = 𝐤(𝐆)ᵀ2πg(𝐑)⁻¹P(𝐑)⁻¹[2πP(𝐑)⁻¹]⁻¹
#               = 𝐤(𝐆)ᵀg(𝐑)⁻¹
#     ⇔  𝐤′(𝐆) = [g(𝐑)⁻¹]ᵀ𝐤(𝐆) = [g(𝐑)ᵀ]⁻¹𝐤(𝐆) 
# where we have used that P(𝐆)ᵀ = 2πP(𝐑)⁻¹ several times. Importantly, this
# essentially shows that we can consider g(𝐆) and g(𝐑) mutually interchangeable
# in practice.
# By similar means, one can show that 
#   [g(𝐑)⁻¹]ᵀ = P(𝐑)ᵀP(𝐑)g(𝐑)[P(𝐑)ᵀP(𝐑)]⁻¹
#             = [P(𝐆)ᵀP(𝐆)]⁻¹g(𝐑)[P(𝐆)ᵀP(𝐆)],
# by using that g(C)ᵀ = g(C)⁻¹ is an orthogonal matrix in the Cartesian basis.
# [ *) We transform from a Cartesian basis to an arbitrary 𝐗ⱼ basis via a 
# [    transformation matrix P(𝐗) = [𝐗₁ 𝐗₂ 𝐗₃] with columns of 𝐗ⱼ; a vector 
# [    v(𝐗) in the 𝐗-representation corresponds to a Cartesian vector v(C)≡v via
# [      v(C) = P(𝐗)v(𝐗)
# [    while an operator O(𝐗) corresponds to a Cartesian operator O(C)≡O via
# [      O(C) = P(𝐗)O(𝐗)P(𝐗)⁻¹
function littlegroup(symops::Vector{SymOperation}, k₀, kabc=zero(eltype(k₀)), cntr='P')
    idxlist = [1]
    checkabc = !iszero(kabc)
    dim = length(k₀)
    for (idx, op) in enumerate(@view symops[2:end]) # note: idx is offset by 1 relative to position of op in symops
        k₀′ = pg(op)'\k₀ # this is k₀(𝐆)′ = [g(𝐑)ᵀ]⁻¹k₀(𝐆)      
        diff = k₀′ .- k₀
        diff = primitivebasismatrix(cntr, dim)'*diff 
        kbool = all(el -> isapprox(el, round(el), atol=1e-11), diff) # check if k₀ and k₀′ differ by a _primitive_ reciprocal vector
        abcbool = checkabc ? isapprox(pg(op)'\kabc, kabc, atol=1e-11) : true # check if kabc == kabc′; no need to check for difference by a reciprocal vec, since kabc is in interior of BZ

        if kbool && abcbool # ⇒ part of little group
            push!(idxlist, idx+1) # `idx+1` is due to previously noted idx offset 
        end
    end
    return idxlist, view(symops, idxlist)
end
littlegroup(sg::SpaceGroup, k₀, kabc=zero(eltype(k₀)), cntr='P') = littlegroup(operations(sg), k₀, kabc, cntr)
littlegroup(symops::Vector{SymOperation}, kv::KVec, cntr='P') = littlegroup(symops, parts(kv)..., cntr)

function starofk(symops::Vector{SymOperation}, k₀, kabc=zero(eltype(k₀)), cntr='P')
    kstar = [KVec(k₀, kabc)]
    checkabc = !iszero(kabc)
    dim = length(k₀)
    for op in (@view symops[2:end])
        k₀′ = pg(op)'\k₀ # this is k(𝐆)′ = [g(𝐑)ᵀ]⁻¹k(𝐆)      
        kabc′ = checkabc ? pg(op)'\kabc : kabc

        oldkbool = false
        for (k₀′′,kabc′′) in kstar
            diff = k₀′ .- k₀′′
            diff = primitivebasismatrix(cntr, dim)'*diff # TODO, generalize to 2D
            kbool = all(el -> isapprox(el, round(el), atol=1e-11), diff) # check if k₀ and k₀′ differ by a _primitive_ reciprocal vector
            abcbool = checkabc ? isapprox(kabc′, kabc′′, atol=1e-11) : true   # check if kabc == kabc′; no need to check for difference by a reciprocal vec, since kabc is in interior of BZ
            oldkbool |= (kbool && abcbool) # means we've haven't already seen this k-vector (mod G)
        end

        if !oldkbool
            push!(kstar, KVec(k₀′, kabc′))
        end
    end
    return kstar
end
starofk(sg::SpaceGroup, k₀, kabc=zero(eltype(k₀)), cntr='P')  = starofk(operations(sg), k₀, kabc, cntr)
starofk(symops::Vector{SymOperation}, kv::KVec, cntr='P') = starofk(symops, parts(kv)..., cntr)


