function simplify(t::Expr)
    postwalk(t) do x
        if !isa(x, Expr)
            return x
        end
        if x.head == :call
            # remove ^0 or ^1
            if x.args[1] == :(^)
                if x.args[3] == 0
                    return 1
                end
                if x.args[3] == 1
                    return x.args[2]
                end
                # replace ^1/2 with sqrt
                if x.args[3] == :(1/2)
                    return :(sqrt($(x.args[2])))
                end
            end
            # remove /1
            if x.args[1] == :(/)
                if x.args[3] == 1
                    return x.args[2]
                end
            end
        end
        return x
    end
end

"""    symbolic_symplify(ex::Expr)

a more thorouugh simplification of an expression,
removes -1/1, *(a,*(b,c)) and *(a,/(b,c)).
"""
function symbolic_symplify(ex::Expr)
    iscall(x) = false
    iscall(x, name::Symbol) = false
    iscall(x::Expr) = x.head == :call
    iscall(x::Expr, name::Symbol) = iscall(x) && x.args[1] == name

    MacroTools.postwalk(ex) do x
        if x == :param
            return :T
        end
        if x == :state
            return :u
        end
        # -1/1 => -1
        if x == :(-1/1)
            return :(-1)
        end
        # +(x) => x
        if iscall(x, :+) && length(x.args)==2
            return x.args[2]
        end
        # 1*x => x
        if iscall(x, :*) && length(x.args)==3 && x.args[2] == 1
            return x.args[3]
        end
        # *(a, *(b,c)) => *(a,b,c)
        if iscall(x, :*) && length(x.args)==3 && iscall(x.args[end], :*)
            return :(*($(x.args[2]), $(x.args[3].args[2:end]...)))
        end
        # *(a, /(b,c)) => /(*(a,b),c)
        if iscall(x, :*) && length(x.args)==3 && iscall(x.args[end], :/)
            a = x.args[2]
            b = x.args[3].args[2]
            c = x.args[3].args[3]
            num = :(*($(a), $(b)))
            # apply *(a, *(b,c)) => *(a,b,c) again
            if iscall(num, :*) && length(num.args)==3 && iscall(num.args[end], :*)
                num = :(*($(num.args[2]), $(num.args[3].args[2:end]...)))
            end
            f = :($num / $c)
            return f
        end
        return x
    end
end

stripnullterms(e) = begin
    newex = MacroTools.postwalk(e) do ex
        if typeof(ex) != Expr; return ex end
        if ex.args[1] != :(*); return ex end
        if ex.args[2] != 0; return ex end
        if ex.args[2] == 0; return 0 end
        return ex
    end
    newex = MacroTools.postwalk(newex) do ex
        if typeof(ex) != Expr; return ex end
        if ex.args[1] != :(+); return ex end
        if ex.args[2] == 0
            return ex.args[3]
        end
        if ex.args[3] == 0
            return ex.args[2]
        end
        return ex
    end
    return newex
end

function funcbody(ex::Equation, ctx=:state)
  return ex.lhs.op.name => funcbody(ex.rhs, ctx)
end

function funcbody(ex::Operation, ctx=:state)
  args = Symbol[]
  body = postwalk(convert(Expr, ex)) do x
    # @show x, typeof(x);
    if typeof(x) == Expr && x.head == :call
      if length(x.args) == 1
        var = x.args[1]
        push!(args, var)
        return :($ctx.$var)
      end
    end
    return x
  end
  return body, Set(args)
end

funckit(fname, args, body) = quote $fname($(collect(args)...)) = $body end
funckit(fname::Symbol, arg::Symbol, body) = quote $fname($arg) = $body end

""" funckit(p::Problem, ctx=:state)

Compile petri net problem to native Julia expressions for faster solving
"""
function funckit(p::Problem, ctx=:state)
  # @show "Λs"
  λf = map(p.m.Λ) do λ
    body, args = funcbody(λ, ctx)
    fname = gensym("λ")
    q = funckit(fname, ctx, body)
    return q
  end
  # @show "Δs"
  δf = map(p.m.Δ) do δ
    q = quote end
    map(δ) do f
      vname, vfunc = funcbody(f, ctx)
      body, args = vfunc
      qi = :(state.$vname = $body)
      push!(q.args, qi)
    end
    sym = gensym("δ")
    :($sym(state) = $(q) )
  end

  # @show "Φs"
  ϕf = map(p.m.Φ) do ϕ
    body, args = funcbody(ϕ, ctx)
    fname = gensym("ϕ")
    q = funckit(fname, ctx, body)
  end
  return Model(p.m.S, δf, λf, ϕf)
end

quotesplat(x) = quote $(x...) end

