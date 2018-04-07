module Examples

import Compat: replace, popfirst!, @error, @info

import JSON, IJulia

# # Some simple rules:
#
# * All lines starting with `#'` are considered markdown, everything else is considered code
# * The file is parsed in "chunks" of code and markdown. A new chunk is created when the
#   lines switch context from markdown to code and vice versa.
# * Lines starting with `#-` can be used to start a new chunk.
# * Lines starting with `#md` are filtered out unless creating a markdown file
# * Lines starting with `#nb` are filtered out unless creating a notebook
# * Lines starting with, or ending with, `#jl` are filtered out unless creating a script file
# * Whitespace within a chunk is preserved
# * Empty chunks are removed, leading and trailing empty lines in a chunk are also removed

# Parser
abstract type Chunk end
struct MDChunk <: Chunk
    lines::Vector{String}
end
MDChunk() = MDChunk(String[])
mutable struct CodeChunk <: Chunk
    lines::Vector{String}
    continued::Bool
end
CodeChunk() = CodeChunk(String[], false)

function parse(content)
    lines = collect(eachline(IOBuffer(content)))

    chunks = Chunk[]
    push!(chunks, startswith(lines[1], "#'") ? MDChunk() : CodeChunk())

    for line in lines
        if startswith(line, "#-") # new chunk
            # assume same as last chunk, will be cleaned up otherwise
            push!(chunks, typeof(chunks[end])())
        elseif startswith(line, "#'") # markdown
            if !(chunks[end] isa MDChunk)
                push!(chunks, MDChunk())
            end
            # remove "#' " and "#'\n"
            line = replace(replace(line, r"^#' " => ""), r"^#'$" => "")
            push!(chunks[end].lines, line)
        else # code
            if !(chunks[end] isa CodeChunk)
                push!(chunks, CodeChunk())
            end
            push!(chunks[end].lines, line)
        end
    end

    # clean up the chunks
    ## remove empty chunks
    filter!(x -> !isempty(x.lines), chunks)
    filter!(x -> !all(y -> isempty(y), x.lines), chunks)
    ## remove leading/trailing empty lines
    for chunk in chunks
        while isempty(chunk.lines[1])
            popfirst!(chunk.lines)
        end
        while isempty(chunk.lines[end])
            pop!(chunk.lines)
        end
    end

    # find code chunks that are continued
    last_code_chunk = 0
    for (i, chunk) in enumerate(chunks)
        isa(chunk, MDChunk) && continue
        if startswith(last(chunk.lines)," ")
            chunk.continued = true
        end
        if startswith(first(chunk.lines)," ")
            chunks[last_code_chunk].continued = true
        end
        last_code_chunk = i
    end

    return chunks
end

filename(str) = first(splitext(last(splitdir(str))))

"""
    Examples.script(inputfile, outputdir; kwargs...)

Create a script file.
"""
function script(inputfile, outputdir; preprocess = identity, postprocess = identity,
                name = filename(inputfile), kwargs...)
    @info "generating plain script file from $(inputfile)"
    # read content
    content = read(inputfile, String)

    # run custom pre-processing from user
    content = preprocess(content)

    # run built in pre-processing:
    ## - normalize line endings
    ## - remove #md lines
    ## - remove #nb lines
    ## - remove leading and trailing #jl
    ## - replace @__NAME__
    for repl in Pair{Any,Any}[
                    "\r\n" => "\n",
                    r"^#md.*\n?"m => "",
                    r"^#nb.*\n?"m => "",
                    r"^#jl "m => "",
                    r" #jl$"m => "",
                    "@__NAME__" => name,
                ]
        content = replace(content, repl)
    end

    # create the script file
    chunks = parse(content)
    ioscript = IOBuffer()
    for chunk in chunks
        if isa(chunk, CodeChunk)
            for line in chunk.lines
                write(ioscript, line, '\n')
            end
            write(ioscript, '\n') # add a newline between each chunk
        end
    end

    # custom post-processing from user
    content = postprocess(String(take!(ioscript)))

    # write to file
    isdir(outputdir) || error("not a directory: $(outputdir)")
    outputfile = joinpath(outputdir, name * ".jl")

    @info "writing result to $(outputfile)"
    write(outputfile, content)

    return outputfile
end

"""
    Examples.markdown(inputfile, outputdir; kwargs...)

Generate a markdown file from the `input` file and write the result to the `output` file.
"""
function markdown(inputfile, outputdir; preprocess = identity, postprocess = identity,
                  name = filename(inputfile),
                  codefence::Pair = "```@example $(name)" => "```", kwargs...)
    @info "generating markdown page from $(inputfile)"
    # read content
    content = read(inputfile, String)

    # run custom pre-processing from user
    content = preprocess(content)

    # run built in pre-processing:
    ## - normalize line endings
    ## - remove #nb lines
    ## - remove leading and trailing #jl lines
    ## - remove leading #md
    ## - replace @__NAME__
    for repl in Pair{Any,Any}[
                    "\r\n" => "\n",
                    r"^#nb.*\n?"m => "",
                    r"^#jl.*\n?"m => "",
                    r".*#jl$\n?"m => "",
                    r"^#md "m => "",
                    "@__NAME__" => name,
                ]
        content = replace(content, repl)
    end

    # create the markdown file
    chunks = parse(content)
    iomd = IOBuffer()
    continued = false
    for chunk in chunks
        if isa(chunk, MDChunk)
            for line in chunk.lines
                write(iomd, line, '\n')
            end
        else # isa(chunk, CodeChunk)
            write(iomd, codefence.first)
            # make sure the code block is finalized if we are printing to ```@example
            if chunk.continued && startswith(codefence.first, "```@example")
                write(iomd, "; continued = true")
            end
            write(iomd, '\n')
            for line in chunk.lines
                write(iomd, line, '\n')
            end
            write(iomd, codefence.second, '\n')
        end
        write(iomd, '\n') # add a newline between each chunk
    end

    # custom post-processing from user
    content = postprocess(String(take!(iomd)))

    # write to file
    isdir(outputdir) || error("not a directory: $(outputdir)")
    outputfile = joinpath(outputdir, name * ".md")

    @info "writing result to $(outputfile)"
    write(outputfile, content)

    return outputfile
end

"""
    Examples.notebook(inputfile, outputdir; kwargs...)

Generate a notebook from `inputfile` and write the result to `outputdir`.
"""
function notebook(inputfile, outputdir; preprocess = identity, postprocess = identity,
                  execute::Bool=false,
                  name = filename(inputfile), kwargs...)
    @info "generating notebook from $(inputfile)"
    # read content
    content = read(inputfile, String)

    # run custom pre-processing from user
    content = preprocess(content)

    # run built in pre-processing:
    ## - normalize line endings
    ## - remove #md lines
    ## - remove leading and trailing #jl lines
    ## - remove leading #nb
    ## - replace @__NAME__
    ## - replace ```math ... ``` with \begin{equation} ... \end{equation}
    for repl in Pair{Any,Any}[
                    "\r\n" => "\n",
                    r"^#md.*\n?"m => "",
                    r"^#jl.*\n?"m => "",
                    r".*#jl$\n?"m => "",
                    r"^#nb "m => "",
                    "@__NAME__" => name,
                    r"```math(.*?)```"s => s"\\begin{equation}\1\\end{equation}",
                ]
        content = replace(content, repl)
    end

    # custom post-processing from user
    content = postprocess(content)

    # create the notebook
    nb = Dict()
    nb["nbformat"] = IJulia.jupyter_vers.major
    nb["nbformat_minor"] = IJulia.jupyter_vers.minor

    ## create the notebook cells
    chunks = parse(content)
    cells = []
    for chunk in chunks
        cell = Dict()
        if isa(chunk, MDChunk)
            cell["cell_type"] = "markdown"
            cell["metadata"] = Dict()
            @views map!(x -> x*'\n', chunk.lines[1:end-1], chunk.lines[1:end-1])
            cell["source"] = chunk.lines
            cell["outputs"] = []
        else # isa(chunk, CodeChunk)
            cell["cell_type"] = "code"
            cell["metadata"] = Dict()
            @views map!(x -> x*'\n', chunk.lines[1:end-1], chunk.lines[1:end-1])
            cell["source"] = chunk.lines
            cell["execution_count"] = nothing
            cell["outputs"] = []
        end
        push!(cells, cell)
    end
    nb["cells"] = cells

    ## create metadata
    metadata = Dict()

    kernelspec = Dict()
    kernelspec["language"] =  "julia"
    kernelspec["name"] =  "julia-$(VERSION.major).$(VERSION.minor)"
    kernelspec["display_name"] = "Julia $(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
    metadata["kernelspec"] = kernelspec

    language_info = Dict()
    language_info["file_extension"] = ".jl"
    language_info["mimetype"] = "application/julia"
    language_info["name"]=  "julia"
    language_info["version"] = "$(VERSION.major).$(VERSION.minor).$(VERSION.patch)"
    metadata["language_info"] = language_info

    nb["metadata"] = metadata

    ionb = IOBuffer()
    JSON.print(ionb, nb, 2)

    # custom post-processing from user
    content = postprocess(String(take!(ionb)))

    # write to file
    isdir(outputdir) || error("not a directory: $(outputdir)")
    outputfile = joinpath(outputdir, name * ".ipynb")

    @info "writing result to $(outputfile)"
    write(outputfile, content)

    if execute
        @info "executing notebook $(outputfile)"
        try
            run(`$(IJulia.jupyter)-nbconvert --ExecutePreprocessor.timeout=-1 --to notebook --execute $(abspath(outputfile)) --output $(filename(outputfile)).ipynb`)
        catch err
            @error "error when executing notebook $(outputfile)"
            rethrow(err)
        end
        # clean up
        rm(joinpath(first(splitdir(outputfile)), ".ipynb_checkpoints"), force=true, recursive = true)
    end

    return outputfile
end

end # module