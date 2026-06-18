[project]
name = "markapatent-mcp-plus"
version = "0.1.0"
description = "TURKPATENT Marka, Patent ve Tasarım Araştırma MCP Sunucusu (Extended)"
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "fastmcp>=2.0.0",
    "httpx>=0.27.0",
    "cachetools>=5.3.0",
    "pydantic>=2.0.0",
]

[project.optional-dependencies]
asgi = [
    "starlette>=0.37.0",
    "uvicorn>=0.30.0",
]

[project.scripts]
markapatent-mcp-plus = "mcp_server:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
include = ["*.py"]
