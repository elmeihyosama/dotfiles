# Load all sheldon-managed plugins (order defined in plugins.toml;
# fast-syntax-highlighting is last so it wraps every widget).
if command -v sheldon >/dev/null 2>&1; then
  eval "$(sheldon source)"
fi
