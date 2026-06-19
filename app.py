"""
ASGI application for TURKPATENT MCP+ Server
"""

from starlette.responses import JSONResponse

from mcp_server import mcp


@mcp.custom_route("/health", methods=["GET"])
async def health_check(request):
    """Health check endpoint"""
    return JSONResponse({
        "status": "healthy",
        "service": "TURKPATENT MCP+ Server",
        "version": "0.1.0",
    })


app = mcp.http_app()
