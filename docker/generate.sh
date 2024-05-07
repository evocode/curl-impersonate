#!/bin/sh

# Check if ./mustache exists
if [ ! -x "./mustache" ]; then
    # Convert autoconf style os name to CMake style os name.
    case $(uname -s) in           \
      Linux*)                    \
        system_name=linux        \
        ;;                       \
      Darwin*)                   \
        system_name=darwin       \
        ;;                       \
      *)                         \
        system_name=$(uname -s)   \
        ;;                       \
    esac

    # Download mustache-cli
    wget -U "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.71 Safari/537.36 Edg/94.0.992.38" \
       -qO- https://github.com/quantumew/mustache-cli/releases/download/v1.0.0/mustache-cli-$system_name-amd64.zip | tar xzf - mustache
    chmod +x ./mustache
fi

cat <<EOF | ./mustache docker/Dockerfile.mustache > docker/debian.dockerfile
---
debian: true
---
EOF

cat <<EOF | ./mustache docker/Dockerfile.mustache > docker/alpine.dockerfile
---
alpine: true
---
EOF

cat <<EOF | ./mustache docker/Dockerfile.mustache > chrome/alpine.dockerfile
---
alpine: true
---
EOF
