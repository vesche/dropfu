import sys


class DropfuPlugin:
    name = "base"
    description = ""

    def run(self, args):
        raise NotImplementedError

    def output(self, text):
        print(text)

    def error(self, msg):
        print(f"error: {msg}", file=sys.stderr)


def main(plugin_class):
    plugin = plugin_class()
    args = sys.argv[1:]
    try:
        plugin.run(args)
    except Exception as e:
        plugin.error(str(e))
