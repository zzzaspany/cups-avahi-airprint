# Two stages. The toolchain that compiles brlaser and gutenprint stays in the builder and never
# reaches the published image.
#
# Why this is a restructure rather than a cleanup: deleting build-base in a later layer would not
# shrink anything. A deletion in a new layer only adds a whiteout over files that remain in the
# layer below, which is how an earlier attempt at a derived image grew from 730 MB to 1.29 GB. The
# only way the toolchain actually leaves is to never be in the final stage at all.
#
# FORK DELTAS from chuckcharlie/cups-avahi-airprint, all four deliberate:
#   1. alpine:3.24 instead of alpine:3.20, which is past end of life. Trivy warns on every scan of
#      a 3.20 image that its vulnerability data may be incomplete, which makes a clean report
#      meaningless rather than reassuring.
#   2. No Alpine `edge` repositories. Upstream appends all three, almost certainly to reach a
#      newer hplip than 3.20 carried; with hplip gone (delta 3) every remaining package is in
#      3.24's own main and community, so the image no longer mixes a stable base with a rolling
#      one.
#   3. Two stages, as above.
#   4. No hplip. HP's driver stack, ten CRITICAL CVEs, nothing in the image depends on it, and this
#      relay fronts a Brother over `socket://`. Re-add it if you front an HP printer - and note the
#      assertion at the bottom of this file, which exists so an upstream merge cannot restore it
#      without the build failing.

FROM docker.io/library/alpine:3.24 AS builder

# Build-only. None of this is in the final stage.
RUN apk add --no-cache build-base cups-dev cmake git wget perl

# brlaser - the Brother laser driver, and the reason this image exists rather than a plain CUPS one.
# CMAKE_POLICY_VERSION_MINIMUM is needed because brlaser's CMakeLists declares compatibility with
# CMake < 3.5, which CMake 4.x refuses by default; 3.24 ships CMake 4.2.
RUN git clone --depth 1 https://github.com/pdewacht/brlaser.git /tmp/brlaser \
 && cd /tmp/brlaser \
 && cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 . \
 && make \
 && make install DESTDIR=/out

# gutenprint. The sed renames a PAGESIZE macro that collides with a system header; without it the
# testpattern sources fail to compile.
RUN wget -q -O /tmp/gutenprint.tar.xz \
      "https://sourceforge.net/projects/gimp-print/files/gutenprint-5.3/5.3.5/gutenprint-5.3.5.tar.xz/download" \
 && mkdir -p /tmp/gutenprint && tar -xJf /tmp/gutenprint.tar.xz -C /tmp/gutenprint --strip-components=1 \
 && cd /tmp/gutenprint \
 && find src/testpattern -type f -exec sed -i 's/\bPAGESIZE\b/GPT_PAGESIZE/g' {} + \
 && ./configure \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out

# Pruned here, in the builder, for the same reason the stages exist at all: removing these after
# the COPY would leave them in the layer below. Measured sizes at the time of writing:
#   locale   21.1M   gutenprint's translated option names; nothing reads them on a headless relay
#   doc       3.6M   including a generated HTML API reference
#   *.a *.la  3.4M   static library and libtool archive
#   samples   656K
#   include   228K   headers
#   bin       172K   escputil and testpattern, both developer tools
# The paths that stay are asserted present in the final stage, so a prune that goes too far fails
# the build rather than producing an image that cannot print.
RUN rm -rf /out/usr/local/share/locale \
           /out/usr/local/share/gutenprint/doc \
           /out/usr/local/share/gutenprint/samples \
           /out/usr/local/include \
           /out/usr/local/lib/pkgconfig \
           /out/usr/local/bin \
 && rm -f  /out/usr/local/lib/*.a /out/usr/local/lib/*.la


FROM docker.io/library/alpine:3.24

# Runtime only. This is upstream's list minus cups-dev, build-base and wget, which are build-only,
# and minus hplip.
#
# Kept although the startup scripts never name them: perl, because /usr/sbin/cups-genppdupdate
# carries a perl shebang, and python3, because cups-filters ships helpers in it. inotify-tools is
# load-bearing and easy to mistake for optional - printer-update.sh runs inotifywait to copy
# printers.conf and cupsd.conf back into /config when cupsd rewrites them, which is the only reason
# a change made through the CUPS admin UI survives a restart.
RUN apk add --no-cache \
      cups \
      cups-libs \
      cups-pdf \
      cups-client \
      cups-filters \
      gcompat \
      ghostscript \
      avahi \
      dbus \
      inotify-tools \
      python3 \
      perl \
      splix \
      tzdata

COPY --from=builder /out/ /

# gutenprint installs this with a configure-time shebang that is not /usr/bin/perl on Alpine.
RUN sed -i '1s|.*|#!/usr/bin/perl|' /usr/sbin/cups-genppdupdate

EXPOSE 631
VOLUME /config

ADD root /
RUN chmod +x /root/*

CMD ["/root/run_cups.sh"]

# Baked-in config changes, unchanged from upstream.
RUN sed -i 's/Listen localhost:631/Listen 0.0.0.0:631/' /etc/cups/cupsd.conf && \
	sed -i 's/Browsing Off/Browsing On/' /etc/cups/cupsd.conf && \
	sed -i 's/IdleExitTimeout/#IdleExitTimeout/' /etc/cups/cupsd.conf && \
	sed -i 's/<Location \/>/<Location \/>\n  Allow All/' /etc/cups/cupsd.conf && \
	sed -i 's/<Location \/admin>/<Location \/admin>\n  Allow All\n  Require user @SYSTEM/' /etc/cups/cupsd.conf && \
	sed -i 's/<Location \/admin\/conf>/<Location \/admin\/conf>\n  Allow All/' /etc/cups/cupsd.conf && \
	sed -i 's/.*enable\-dbus=.*/enable\-dbus\=yes/' /etc/avahi/avahi-daemon.conf && \
	echo "ServerAlias *" >> /etc/cups/cupsd.conf && \
	echo "DefaultEncryption Never" >> /etc/cups/cupsd.conf && \
	echo "ReadyPaperSizes A4,TA4,4X6FULL,T4X6FULL,2L,T2L,A6,A5,B5,L,TL,INDEX5,8x10,T8x10,4X7,T4X7,Postcard,TPostcard,ENV10,EnvDL,ENVC6,Letter,Legal" >> /etc/cups/cupsd.conf && \
	echo "DefaultPaperSize Letter" >> /etc/cups/cupsd.conf && \
	echo "pdftops-renderer ghostscript" >> /etc/cups/cupsd.conf

# Assert the OUTCOMES of everything above, not the commands.
#
# A `sed -i` whose pattern does not match exits 0 and changes nothing, so a base-image update can
# silently drop one of the edits above and the build still succeeds. The cost of that is not
# cosmetic: lose the first line and cupsd listens on localhost only, and AirPrint stops working
# with nothing in any log to say why.
#
# One of these is already known to be a no-op and is written to tolerate it. `Browsing Off` does not
# match on 3.24, whose default is `Browsing Yes` - and it did not match on 3.20 either; both
# published images carry `Browsing Yes`, so upstream's second sed has never done anything. The
# default is already what is wanted, so the assertion accepts Yes or On rather than demanding the
# substitution.
RUN set -eu; \
    c=/etc/cups/cupsd.conf; a=/etc/avahi/avahi-daemon.conf; \
    grep -qxF 'Listen 0.0.0.0:631'       "$c" || { echo 'FAIL: cupsd would listen on localhost only'; exit 1; }; \
    grep -qE '^Browsing (Yes|On)$'       "$c" || { echo 'FAIL: Browsing is not enabled'; exit 1; }; \
    grep -qE '^#IdleExitTimeout'         "$c" || { echo 'FAIL: IdleExitTimeout not commented out'; exit 1; }; \
    grep -q  'Allow All'                 "$c" || { echo 'FAIL: no Allow All in any Location'; exit 1; }; \
    grep -qxF 'ServerAlias *'            "$c" || { echo 'FAIL: ServerAlias missing'; exit 1; }; \
    grep -qxF 'DefaultEncryption Never'  "$c" || { echo 'FAIL: DefaultEncryption missing'; exit 1; }; \
    grep -qxF 'enable-dbus=yes'          "$a" || { echo 'FAIL: avahi will not talk to cupsd over D-Bus'; exit 1; }; \
    echo 'OK: config edits all took effect'

# Assert the image can actually drive a printer.
#
# The two filters are compiled from source in the builder; if either compile silently produced
# nothing, the image still starts and still cannot print.
#
# The library check asks whether anything is UNRESOLVED, and deliberately does not ask whether
# libgutenprint appears. A first version of this asserted the filter resolves libgutenprint and
# failed the build - wrongly. Measured on both the published image that prints today and this one:
# nothing links libgutenprint.so dynamically. Both rastertogutenprint.5.3 and the gutenprint.5.3
# driver have it compiled in statically, and all four binaries below report zero unresolved
# libraries. /usr/local/lib/libgutenprint.so* is kept anyway, since 2.5 MB is not worth assuming
# nothing dlopens it.
#
# Changing the base image is what makes this check worth having: the filters are built against
# whichever libraries the builder stage has, and a mismatch would show up here as `not found`
# rather than as a failed print weeks later.
RUN set -eu; \
    test -x /usr/sbin/cupsd; \
    test -x /usr/sbin/avahi-daemon; \
    test -x /usr/bin/inotifywait; \
    test -x /usr/lib/cups/backend/socket; \
    test -x /usr/lib/cups/backend/dnssd; \
    test -x /usr/lib/cups/backend/ipp; \
    test -x /usr/lib/cups/filter/rastertobrlaser; \
    test -x /usr/lib/cups/filter/rastertogutenprint.5.3; \
    test -d /usr/local/share/gutenprint/5.3/xml; \
    test -x /usr/sbin/cups-genppdupdate; \
    head -1 /usr/sbin/cups-genppdupdate | grep -qx '#!/usr/bin/perl'; \
    command -v perl >/dev/null; \
    for b in /usr/lib/cups/filter/rastertogutenprint.5.3 \
             /usr/lib/cups/driver/gutenprint.5.3 \
             /usr/lib/cups/filter/rastertobrlaser \
             /usr/sbin/cupsd; do \
      out=$(ldd "$b" 2>&1) || { echo "FAIL: ldd could not read $b"; exit 1; }; \
      case "$out" in *"not found"*) echo "FAIL: $b has unresolved libraries"; echo "$out"; exit 1;; esac; \
      n=$(printf '%s\n' "$out" | grep -c '=>' || true); \
      [ "$n" -gt 0 ] || { echo "FAIL: ldd listed no libraries for $b, so this check proved nothing"; exit 1; }; \
      echo "   $b: $n libraries, none unresolved"; \
    done; \
    ! apk info -e hplip; \
    echo 'OK: filters present, libraries resolve, hplip absent'
