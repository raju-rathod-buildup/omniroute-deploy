// Local cross-encoder reranker — speaks the same /v1/rerank shape the gateway sends.
//
// Exists so memory rerank costs nothing and makes no outbound call. The gateway's
// built-in rerank registry is entirely cloud (Cohere/Jina/Voyage/...), but
// src/app/api/v1/rerank/route.ts also accepts "local provider_nodes" whose baseUrl
// resolves to localhost/127.0.0.1/172.16-31.x.x. This service is that node.
//
// Model: Xenova/ms-marco-MiniLM-L-6-v2, a cross-encoder that scores (query, doc)
// pairs directly — strictly better ordering than cosine similarity over independent
// embeddings, which is what the memory engine falls back to without a reranker.
import http from "node:http";
import { AutoTokenizer, AutoModelForSequenceClassification } from "@huggingface/transformers";

const MODEL_ID = process.env.RERANK_MODEL || "Xenova/ms-marco-MiniLM-L-6-v2";
const PORT = Number(process.env.PORT || 8790);

console.log(`[local-rerank] loading ${MODEL_ID} ...`);
const tokenizer = await AutoTokenizer.from_pretrained(MODEL_ID);
const model = await AutoModelForSequenceClassification.from_pretrained(MODEL_ID, {
  dtype: "q8",
});
console.log(`[local-rerank] ready on :${PORT}`);

async function rerank(query, documents) {
  // Cross-encoder: every document is scored jointly with the query in one batch.
  const inputs = tokenizer(new Array(documents.length).fill(query), {
    text_pair: documents,
    padding: true,
    truncation: true,
  });
  const { logits } = await model(inputs);
  return logits.tolist().map((l, i) => ({ index: i, relevance_score: l[0] }));
}

http
  .createServer((req, res) => {
    // Advertise the model so the gateway's provider listing can populate the
    // dashboard dropdown. listEmbeddingProviders() builds local nodes with an
    // empty model array, so without a models endpoint (and patch 0009 to read
    // it) a local reranker is configured-but-invisible in the UI.
    if (req.method === "GET" && req.url.endsWith("/models")) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(
        JSON.stringify({
          object: "list",
          data: [{ id: MODEL_ID.split("/").pop(), object: "model", owned_by: "localrerank" }],
        })
      );
    }
    if (req.method !== "POST" || !req.url.endsWith("/rerank")) {
      res.writeHead(404, { "content-type": "application/json" });
      return res.end(JSON.stringify({ error: "not found" }));
    }
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", async () => {
      try {
        const { query, documents = [], top_n } = JSON.parse(raw || "{}");
        if (typeof query !== "string" || !Array.isArray(documents) || documents.length === 0) {
          res.writeHead(400, { "content-type": "application/json" });
          return res.end(JSON.stringify({ error: "query and documents are required" }));
        }
        const t = Date.now();
        let results = await rerank(query, documents.map(String));
        results.sort((a, b) => b.relevance_score - a.relevance_score);
        if (Number.isFinite(top_n)) results = results.slice(0, top_n);
        console.log(`[local-rerank] ${documents.length} docs in ${Date.now() - t}ms`);
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ model: MODEL_ID, results }));
      } catch (e) {
        console.error("[local-rerank] error", e);
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: String(e) }));
      }
    });
  })
  .listen(PORT, "0.0.0.0");
