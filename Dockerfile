# =============================================================================
# jdoo - Universal Odoo Docker Image (Supports Odoo 15.0 - 19.0+)
# =============================================================================
# Multi-stage build: builder compiles C extensions, runtime is lean (~350MB less)
#
# Build examples:
#   docker compose up -d --build
#   docker build --build-arg ODOO_VERSION=17.0 --build-arg PYTHON_VERSION=3.12 -t jdoo:17 .
# =============================================================================

# -----------------------------------------------------------------------------
# Build Arguments (set via .env or --build-arg)
# -----------------------------------------------------------------------------
ARG PYTHON_VERSION=3.12

# =============================================================================
# Stage 1: BUILDER - compile Python C extensions and clone Odoo
# =============================================================================
FROM python:${PYTHON_VERSION}-slim AS builder

ARG PYTHON_VERSION=3.12
ARG ODOO_VERSION=19.0
ARG ODOO_REPO=https://github.com/autocme/oc.git

# Build tools + development headers (needed for Python C extensions)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential gcc g++ git \
        libpq-dev \
        libxml2-dev libxslt1-dev \
        libldap2-dev libsasl2-dev \
        libjpeg-dev zlib1g-dev libpng-dev \
        libfreetype6-dev liblcms2-dev libtiff-dev \
        libwebp-dev libopenjp2-7-dev \
        libharfbuzz-dev libfribidi-dev libxcb1-dev \
        libffi-dev libssl-dev \
        libblas-dev liblapack-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

# Clone Odoo source code
RUN set -eux; \
    git clone --depth 1 --branch ${ODOO_VERSION} \
        ${ODOO_REPO} /opt/odoo; \
    rm -rf /opt/odoo/.git; \
    mkdir -p /opt/odoo/addons

# Install Python dependencies (version-aware)
RUN set -eux; \
    pip install --no-cache-dir --upgrade pip wheel; \
    pip install --no-cache-dir "setuptools<81"; \
    \
    MAJOR=$(echo "${ODOO_VERSION}" | cut -d. -f1); \
    \
    # Odoo 15-16 need pinned versions for Python 3.10 compatibility \
    # requirements.txt handles cryptography/pyopenssl/urllib3 version pins \
    if [ "$MAJOR" -le 16 ]; then \
        pip install --no-cache-dir \
            greenlet==3.0.3 \
            gevent==23.9.1 \
            reportlab==3.6.13 \
            Pillow==9.5.0; \
        grep -v -i -E "^(gevent|reportlab|pillow|greenlet)[=><~!]" \
            /opt/odoo/requirements.txt > /tmp/requirements-filtered.txt; \
    else \
        cp /opt/odoo/requirements.txt /tmp/requirements-filtered.txt; \
    fi; \
    \
    pip install --no-cache-dir -r /tmp/requirements-filtered.txt; \
    rm -f /tmp/requirements-filtered.txt; \
    \
    # Common Odoo dependencies (all versions) \
    pip install --no-cache-dir \
        phonenumbers \
        python-stdnum \
        vobject \
        xlrd \
        xlwt \
        num2words \
        passlib \
        polib; \
    \
    # click-odoo tools for DB init and auto-upgrade \
    pip install --no-cache-dir \
        click-odoo \
        click-odoo-contrib \
        manifestoo

# =============================================================================
# Stage 2: RUNTIME - lean image without compilers or -dev headers
# =============================================================================
FROM python:${PYTHON_VERSION}-slim

ARG PYTHON_VERSION=3.12
ARG ODOO_VERSION=19.0
ARG WKHTMLTOPDF_VERSION=0.12.6.1-2
ARG NODE_VERSION=20

LABEL maintainer="jaah" \
      description="jdoo - Universal Odoo ${ODOO_VERSION}" \
      odoo.version="${ODOO_VERSION}" \
      python.version="${PYTHON_VERSION}"

# -----------------------------------------------------------------------------
# Environment Variables (runtime defaults)
# -----------------------------------------------------------------------------
ENV ODOO_VERSION=${ODOO_VERSION} \
    ODOO_SOURCE=/opt/odoo \
    ERP_CONF_PATH=/etc/odoo/erp.conf \
    ODOO_DATA_DIR=/var/lib/odoo \
    ODOO_PORT=8069 \
    PUID=1000 \
    PGID=1000 \
    AUTO_UPGRADE=FALSE \
    ODOO_DB_NAME="" \
    INITDB_OPTIONS="" \
    PY_INSTALL="" \
    NPM_INSTALL=""

# -----------------------------------------------------------------------------
# Runtime Libraries Only (no -dev headers, no compilers, no git)
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # Network utilities
        curl \
        wget \
        ca-certificates \
        gnupg \
        # PostgreSQL client (needed for auto-upgrade DB discovery)
        libpq5 \
        postgresql-client \
        # Runtime shared libraries (matching build-time -dev packages)
        libxml2 \
        libxslt1.1 \
        libldap2 \
        libsasl2-2 \
        libjpeg62-turbo \
        libpng16-16t64 \
        libfreetype6 \
        liblcms2-2 \
        libtiff6 \
        libwebp7 \
        libopenjp2-7 \
        # Text rendering (RTL languages, Arabic, etc.)
        libharfbuzz0b \
        libfribidi0 \
        # X11
        libxcb1 \
        # Other runtime libs
        libffi8 \
        libssl3t64 \
        libblas3 \
        liblapack3 \
        # Fonts (PDF generation)
        fonts-liberation \
        fonts-dejavu-core \
        fontconfig \
        # Utilities
        xz-utils \
        zip \
        unzip \
        sudo \
        gosu \
        nano \
    ; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Install libssl1.1 (required by wkhtmltopdf on Debian Bookworm+)
# -----------------------------------------------------------------------------
RUN set -eux; \
    echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list.d/bullseye.list; \
    printf "Package: *\nPin: release n=bullseye\nPin-Priority: 100\n" > /etc/apt/preferences.d/bullseye; \
    apt-get update; \
    apt-get install -y --no-install-recommends libssl1.1; \
    rm -rf /var/lib/apt/lists/* \
           /etc/apt/sources.list.d/bullseye.list \
           /etc/apt/preferences.d/bullseye

# -----------------------------------------------------------------------------
# Install wkhtmltopdf (patched Qt version for Odoo PDF reports)
# Architecture-aware: supports amd64 and arm64
# -----------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
        amd64) WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.bullseye_amd64.deb" ;; \
        arm64) WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.bullseye_arm64.deb" ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/wkhtmltox.deb "$WKHTMLTOPDF_URL"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb; \
    rm -rf /tmp/wkhtmltox.deb /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Install Node.js and npm
# -----------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g npm@latest; \
    rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Create odoo user and directories
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd --gid 1000 odoo; \
    useradd --uid 1000 --gid odoo --shell /bin/bash --create-home odoo; \
    mkdir -p /opt/odoo \
             /etc/odoo \
             /var/lib/odoo \
             /var/lib/odoo/logs \
             /mnt/extra-addons \
             /mnt/synced-addons; \
    chown -R odoo:odoo /opt/odoo /etc/odoo /var/lib/odoo /mnt/extra-addons /mnt/synced-addons

# -----------------------------------------------------------------------------
# Copy compiled Python packages and scripts from builder
# (includes site-packages, pip, click-odoo-*, etc.)
# -----------------------------------------------------------------------------
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/bin/ /usr/local/bin/

# -----------------------------------------------------------------------------
# Copy Odoo source code from builder
# -----------------------------------------------------------------------------
COPY --from=builder --chown=odoo:odoo /opt/odoo /opt/odoo

# -----------------------------------------------------------------------------
# Set PYTHONPATH so 'import odoo' works for click-odoo
# -----------------------------------------------------------------------------
ENV PYTHONPATH="${ODOO_SOURCE}:${PYTHONPATH:-}"

# -----------------------------------------------------------------------------
# Copy entrypoint script
# -----------------------------------------------------------------------------
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=755 healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chmod=755 upgrade.sh /usr/local/bin/upgrade.sh
COPY --chmod=755 addons-path.sh /usr/local/bin/addons-path.sh

WORKDIR /opt/odoo

EXPOSE 8069 8072

VOLUME ["/var/lib/odoo", "/mnt/extra-addons"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["odoo"]
