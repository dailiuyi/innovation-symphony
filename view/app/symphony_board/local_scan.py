"""Fixed isolated subprocess entrypoint for the shared read-only scanner."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from symphony_board.wslpull import remote_script

if __name__ == "__main__":
    exec(compile(remote_script(json.loads(sys.argv[1]), local=True), "<runtime-scan>", "exec"))
