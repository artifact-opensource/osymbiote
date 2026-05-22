#!/bin/sh
echo "Testing OSymbiote agent..."
echo ""

echo "=== Health ==="
curl -s http://localhost:18422/health 2>/dev/null && echo ""

echo ""
echo "=== Hardware ==="
curl -s http://localhost:18422/hardware 2>/dev/null && echo ""

echo ""
echo "=== Chat ==="
curl -s -X POST -d "Hello, are you alive?" http://localhost:18422/chat 2>/dev/null && echo ""

echo ""
echo "=== COMB Stage ==="
curl -s -X POST -d "Test memory entry from outside" http://localhost:18422/comb/stage 2>/dev/null && echo ""

echo ""
echo "=== COMB Recall ==="
curl -s http://localhost:18422/comb/recall 2>/dev/null && echo ""

echo ""
echo "Done."
