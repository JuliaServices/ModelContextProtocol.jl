using Documenter
using ModelContextProtocol

DocMeta.setdocmeta!(
    ModelContextProtocol,
    :DocTestSetup,
    :(using ModelContextProtocol);
    recursive=true,
)

makedocs(
    modules=[ModelContextProtocol],
    sitename="ModelContextProtocol.jl",
    format=Documenter.HTML(
        prettyurls=true,
        canonical="https://JuliaServices.github.io/ModelContextProtocol.jl/stable",
        collapselevel=2,
    ),
    pages=[
        "Home" => "index.md",
        "Auth0 Federation Example" => "auth0.md",
        "API" => "api.md",
    ],
    pagesonly=true,
    checkdocs=:none,
)

deploydocs(
    repo="github.com/JuliaServices/ModelContextProtocol.jl.git",
    devbranch="main",
    push_preview=true,
)
