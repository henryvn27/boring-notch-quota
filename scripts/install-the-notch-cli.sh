#!/bin/sh
set -eu

prefix="${THE_NOTCH_CLI_PREFIX:-$HOME/.local}"
share="$prefix/share/the-notch-cli"
bin="$prefix/bin"
mkdir -p "$share" "$bin"
cp "$(CDPATH= cd -- "$(dirname -- "$0")/../cli" && pwd)/the_notch.py" "$share/the_notch.py"
cat > "$bin/the-notch" <<EOF
#!/bin/sh
exec python3 "$share/the_notch.py" "\$@"
EOF
chmod 755 "$bin/the-notch" "$share/the_notch.py"
printf 'Installed the-notch to %s\n' "$bin/the-notch"
case ":${PATH}:" in
  *":$bin:"*) ;;
  *) printf 'Add %s to PATH to run it directly.\n' "$bin" ;;
esac
