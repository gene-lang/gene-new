## Public web compiler entry point. Macro bodies use the ordinary VM during
## host-side compilation, including when a tool imports only gene/web.
## The VM imports web_backend directly for embedded assets to avoid a cycle.
import ./vm # installs the ordinary macro-body evaluator
import ./web_backend
export web_backend
