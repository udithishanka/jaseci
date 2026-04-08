"""Implementation of ServiceResponse methods."""

import json;

"""Parse response body as JSON."""
impl ServiceResponse.json -> Any {
    return json.loads(self._body);
}

"""Return response body as string."""
impl ServiceResponse.text -> str {
    if isinstance(self._body, bytes) {
        return self._body.decode("utf-8");
    }
    return str(self._body);
}
