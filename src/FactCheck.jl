######################################################################
# FactCheck.jl
# A testing framework for Julia
# http://github.com/JuliaLang/FactCheck.jl
# MIT Licensed
######################################################################

module FactCheck

export @fact, @fact_throws,
       facts, context,
       getstats, exitstatus,
       # Assertion helpers
       not,
       anything,
       truthy, falsey, falsy,
       exactly,
       roughly

######################################################################
# Success, Failure, Error <: Result
# Represents the result of a test. These are very similar to the types 
# with the same names in Base.Test, except for the addition of the
# `meta` dictionary that is used to retain information about the test,
# such as its file, line number, description, etc.
abstract Result
type Success <: Result
    expr::Expr
    val
    meta::Dict
end
type Failure <: Result
    expr::Expr
    val
    meta::Dict
end
type Error <: Result
    expr::Expr
    err::Exception
    backtrace
    meta::Dict
end

# Collection of all results across facts
allresults = Result[]
clear_results() = (global allresults; allresults = Result[])

# Formats a FactCheck assertion
# e.g. :(fn(1) => 2) to  `fn(1) => 2`
function format_assertion(ex::Expr)
    x, y = ex.args
    "$x => $y"
end

# Builds string with line and context annotations, if available
format_line(r::Result) = string(
    haskey(r.meta, :line) ? " :: (line:$(r.meta[:line]))" : "",
    isempty(contexts) ? "" : " :: $(contexts[end])",
    get(r.meta,:msg,nothing) != nothing ? " :: $(r.meta[:msg])" : "")

# Define printing functions for the result types
function Base.show(io::IO, f::Failure)
    indent = isempty(handlers) ? "" : "  "
    print_with_color(:red, io, indent, "Failure")
    println(io, indent, format_line(f), " :: got ", f.val)
    print(io, indent^2, format_assertion(f.expr))
end
function Base.show(io::IO, e::Error)
    indent = isempty(handlers) ? "" : "  "
    print_with_color(:red, io, indent, "Error")
    println(io, indent, format_line(e))
    println(io, indent^2, format_assertion(e.expr))
    Base.showerror(io, e.err, e.backtrace)
    print(io)
end
function Base.show(io::IO, s::Success)
    indent = isempty(handlers) ? "" : "  "
    print_with_color(:green, io, indent, "Success")
    print(io, " :: $(format_assertion(s.expr))")
end

######################################################################
# Core testing macros and functions

# `@fact` is the workhorse macro. It
# * takes in the expresion-assertion pair, 
# * converts it to a function that returns tuple (success, assertval)
# * processes and stores result of test [do_fact]
macro fact(factex::Expr, args...)
    factex.head != :(=>) && error("Incorrect usage of @fact: $factex")
    expr, assertion = factex.args
    msg = length(args) > 0 ? args[1] : :nothing
    quote
        pred = function(t)
            e = $(esc(assertion))
            isa(e, Function) ? (e(t), t) : (e == t, t)
        end
        
        do_fact(() -> pred($(esc(expr))),
                $(Expr(:quote, factex)),
                [:line => getline(),
                 :msg  => $(esc(msg))] )
    end
end

# `@fact_throws` is similar to `@fact`, except it only checks if
# the expression throws an error or not - there is no explict 
# assertion to compare against.
macro fact_throws(factex::Expr, args...)
    msg = length(args) > 0 ? args[1] : :nothing
    quote
        do_fact(()  ->  try
                            $(esc(factex))
                            (false, "no error")
                        catch e
                            (true, "error")
                        end,
                $(Expr(:quote, factex)),
                [:line => getline(),
                 :msg  => $(esc(msg))] )
    end
end


# `do_fact` constructs a Success, Failure, or Error depending on the 
# outcome of a test and passes it off to the active test handler
# `FactCheck.handlers[end]`. It finally returns the test result.
function do_fact(thunk::Function, factex::Expr, meta::Dict)
    result = try
        res, val = thunk()
        res ? Success(factex, val, meta) : Failure(factex, val, meta)
    catch err
        Error(factex, err, catch_backtrace(), meta)
    end

    !isempty(handlers) && handlers[end](result)
    push!(allresults, result)
    result
end

######################################################################
# Grouping of tests
#
# `facts` describes a top-level test scope, which can contain
# `contexts` to group similar tests. Test results will be collected
# instead of throwing an exception immediately.

# A TestSuite collects the results of a series of tests, as well as
# some information about the tests such as their file and description.
type TestSuite
    filename
    desc
    successes::Array{Success}
    failures::Array{Failure}
    errors::Array{Error}
end
TestSuite(f, d) = TestSuite(f, d, Success[], Failure[], Error[])

function Base.print(io::IO, suite::TestSuite)
    n_succ = length(suite.successes)
    n_fail = length(suite.failures)
    n_err  = length(suite.errors)
    if n_fail == 0 && n_err == 0
        print_with_color(:green, io, "$n_succ $(pluralize("fact", n_succ)) verified.\n")
    else
        total = n_succ + n_fail + n_err
        println(io, "Out of $total total $(pluralize("fact", total)):")
        print_with_color(:green, io, "  Verified: $n_succ\n")
        print_with_color(:red,   io, "  Failed:   $n_fail\n")
        print_with_color(:red,   io, "  Errored:  $n_err\n")
    end
end

function print_header(suite::TestSuite)
    print_with_color(:bold, 
        suite.desc     != nothing ? "$(suite.desc) " : "", 
        suite.filename != nothing ? "($(suite.filename))" : "", "\n")
end

# The last handler function found in `handlers` will be passed
# test results.
const handlers = Function[]

# A list of test contexts. `contexts[end]` should be the 
# inner-most context.
const contexts = String[]

# Constructs a function that handles Successes, Failures, and Errors,
# pushing them into a given TestSuite and printing Failures and Errors
# as they arrive.
function make_handler(suite::TestSuite)
    function delayed_handler(r::Success)
        push!(suite.successes, r)
    end
    function delayed_handler(r::Failure)
        push!(suite.failures, r)
        println(r)
    end
    function delayed_handler(r::Error)
        push!(suite.errors, r)
        println(r)
    end
    delayed_handler
end

# facts
# Creates testing scope. It is responsible for setting up a testing
# environment, which means constructing a `TestSuite`, generating
# and registering test handlers, and reporting results.
function facts(f::Function, desc)
    suite = TestSuite(nothing, desc)
    handler = make_handler(suite)
    push!(handlers, handler)
    print_header(suite)
    f()
    print(suite)
    pop!(handlers)
end
facts(f::Function) = facts(f, nothing)

# context
# Executes a battery of tests in some descriptive context, intended
# for use inside of facts
function context(f::Function, desc::String)
    push!(contexts, desc)
    f()
    pop!(contexts)
end
context(f::Function) = f()


######################################################################

# HACK: get the current line number
#
# This only works inside of a function body:
#
#     julia> hmm = function()
#                2
#                3
#                getline()
#            end
#
#     julia> hmm()
#     4
#
function getline()
    bt = backtrace()
    issecond = false
    for frame in bt
        lookup = ccall(:jl_lookup_code_address, Any, (Ptr{Void}, Int32), frame, 0)
        if lookup != ()
            if issecond
                return lookup[3]
            else
                issecond = true
            end
        end
    end
end

pluralize(s::String, n::Number) = n == 1 ? s : string(s, "s")

# `getstats` return a dictionary with a summary over all tests run
function getstats()
    s = 0
    f = 0
    e = 0
    for r in allresults
        if isa(r, Success)
            s += 1
        elseif isa(r, Failure)
            f += 1
        elseif isa(r, Error)
            e += 1
        end
    end
    assert(s+f+e == length(allresults))
    {"nSuccesses" => s, "nFailures" => f, "nErrors" => e, "nNonSuccessful" => f+e}
end

function exitstatus()
    ns = getstats()["nNonSuccessful"]
    ns > 0 && error("FactCheck finished with $ns non-successful tests.")
end

############################################################
# Assertion helpers
include("helpers.jl")


end # module FactCheck