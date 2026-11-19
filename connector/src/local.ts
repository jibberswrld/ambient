import { createServer } from "node:http";
import { handleNodeRequest } from "./http.ts";

createServer(handleNodeRequest).listen(3019, "127.0.0.1", () => {
  console.log("Ambient connector listening at http://127.0.0.1:3019");
});
