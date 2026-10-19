#!/bin/bash

clear
echo "PiModem Builder v0.1"
echo "--------------------"

# Hosts that must always be treated as raw TCP (no telnet negotiation or
# telnet auto-detection). Everything else keeps stock tcpser behavior.
RAW_HOST="nwnrevival.com"

# Write the tcpser patcher to a temp file. This is done here, outside the
# && chain below, because a heredoc can't sit mid-chain.
cat > /tmp/tcpser-rawhost-patch.py << 'EOF'
import sys
host = sys.argv[1]

# modem_core.h: per-connection flag
p = "src/modem_core.h"
s = open(p).read()
old = "  int first_char;\n  nvt_vars nvt_data;\n} line_config;"
assert old in s, "modem_core.h layout changed"
s = s.replace(old, "  int first_char;\n  int force_raw;   /* PiModem patch: skip telnet handling for listed hosts */\n  nvt_vars nvt_data;\n} line_config;")
open(p, "w").write(s)

# line.c: decide raw vs. telnet when the call is placed
p = "src/line.c"
s = open(p).read()
assert '#include "line.h"\n' in s, "line.c layout changed"
s = s.replace('#include "line.h"\n',
'''#include "line.h"
#include <ctype.h>
#include <string.h>

/* PiModem patch: destinations that must always be treated as raw TCP.
 * Matched as a case-insensitive substring of the resolved address
 * (after phonebook lookup). Add more entries before the NULL. */
static const char *raw_hosts[] = { "%s", NULL };

static int host_is_raw(const char *addy)
{
  char buf[256];
  int i;

  for (i = 0; addy[i] && i < 255; i++)
    buf[i] = tolower((unsigned char) addy[i]);
  buf[i] = 0;
  for (i = 0; raw_hosts[i]; i++)
    if (strstr(buf, raw_hosts[i]))
      return TRUE;
  return FALSE;
}
''' % host.lower(), 1)

old = "  cfg->line_data.first_char = TRUE;\n  cfg->line_data.valid_conn = FALSE;\n  nvt_init_config"
assert old in s, "line_init_config changed"
s = s.replace(old, "  cfg->line_data.first_char = TRUE;\n  cfg->line_data.force_raw = FALSE;\n  cfg->line_data.valid_conn = FALSE;\n  nvt_init_config", 1)

old = "  addy = pb_search(addy);\n  cfg->line_data.fd = ip_connect(addy);\n"
assert old in s, "line_connect changed"
s = s.replace(old, "  addy = pb_search(addy);\n  cfg->line_data.force_raw = host_is_raw(addy);\n  if (cfg->line_data.force_raw)\n    LOG(LOG_INFO, \"Raw TCP host, telnet handling disabled\");\n  cfg->line_data.fd = ip_connect(addy);\n", 1)

old = "    send_nvt_command(cfg->line_data.fd, &cfg->line_data.nvt_data, NVT_WILL, NVT_OPT_ECHO);\n"
assert old in s, "ECHO negotiation changed"
s = s.replace(old, "    if (!cfg->line_data.force_raw)\n  " + old, 1)

old = "    if (!cfg->parity) {\n      send_nvt_command"
assert old in s, "binary negotiation changed"
s = s.replace(old, "    if (!cfg->parity && !cfg->line_data.force_raw) {\n      send_nvt_command", 1)
open(p, "w").write(s)

# bridge.c: skip auto-detection for raw hosts
p = "src/bridge.c"
s = open(p).read()
old = "    if ((data[0] == 0xff) || (data[0] == 0x1a)) {"
assert old in s, "bridge.c detection changed"
s = s.replace(old, "    if (!cfg->line_data.force_raw && ((data[0] == 0xff) || (data[0] == 0x1a))) {", 1)
open(p, "w").write(s)
EOF

echo -n "Installing prerequisites..."
if sudo apt-get update --allow-releaseinfo-change > /dev/null 2>&1 \
    && sudo apt-get install -y iptables ppp inetutils-telnet xinetd telnetd-ssl python3 > /dev/null 2>&1 \
    && cd /tmp \
    && rm -rf tcpser-master master.zip \
    && wget -q -O master.zip https://github.com/FozzTexx/tcpser/archive/refs/heads/master.zip \
    && unzip -q master.zip \
    && cd tcpser-master \
    && python3 /tmp/tcpser-rawhost-patch.py "$RAW_HOST" \
    && make > /dev/null 2>&1 \
    && { sudo systemctl stop tcpser > /dev/null 2>&1 || true; } \
    && sudo cp -p tcpser /usr/local/bin > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Enabling Network Address Translation and IPv4 port-forwarding..."
if sudo debconf-set-selections << 'EOF'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF
then
    # NOTE: heredocs can't be placed mid-chain before an "&&" on the next line,
    # so the sysctl file is written with echo | tee instead.
    if { sudo iptables -t nat -C POSTROUTING -o wlan0 -j MASQUERADE > /dev/null 2>&1 \
            || sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE > /dev/null 2>&1; } \
        && sudo apt-get install -y iptables-persistent > /dev/null 2>&1 \
        && echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-pimodem-ip-forward.conf > /dev/null \
        && sudo sysctl --system > /dev/null 2>&1; then
        echo "Done"
    else
        echo "Failed"
        exit 1
    fi
else
    echo "Failed"
    exit 1
fi

echo -n "Creating TCPSER startup scripts..."
sudo tee /usr/local/bin/start_tcpser.sh > /dev/null << 'EOF'
#!/bin/bash
phonebook="/home/pi/phonebook.txt"
baud='9600'
dev='/dev/ttyUSB0'
for i in $(cat $phonebook); do
    n="$n -n$i "
done
/usr/local/bin/tcpser -s ${baud} -d ${dev} $n -i '&C0&K3'
EOF

sudo tee /etc/systemd/system/tcpser.service > /dev/null << 'EOF'
[Unit]
Description=Modem emulator tcpser
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/start_tcpser.sh
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

sudo tee /home/pi/phonebook.txt > /dev/null << 'EOF'
5551000=bbs.fozztexx.com
5551001=particlesbbs.dyndns.org:6400
5559000=localhost:2323
EOF

if sudo chmod 755 /usr/local/bin/start_tcpser.sh \
    && sudo systemctl daemon-reload \
    && sudo systemctl enable tcpser > /dev/null 2>&1 \
    && sudo systemctl start tcpser > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating quick config helper..."
sudo tee /usr/local/bin/pimodem-baud > /dev/null << 'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Current baud rate setting:"
    grep "baud=" /usr/local/bin/start_tcpser.sh | head -1
    echo
    echo "Usage: pimodem-baud <rate>"
    echo "Example: pimodem-baud 2400"
    echo
    echo "Common rates: 300, 1200, 2400, 9600, 19200, 38400"
    exit 1
fi

echo "Changing baud rate to: $1"

# Update the baud rate in the script
if sudo sed -i "s/baud='[0-9]*/baud='$1/" /usr/local/bin/start_tcpser.sh; then
    echo "Configuration updated successfully"

    # Restart tcpser service
    echo "Restarting tcpser service..."
    if sudo systemctl restart tcpser; then
        echo "tcpser restarted successfully"

        # Show status
        sleep 2
        echo
        echo "Service status:"
        sudo systemctl --no-pager status tcpser
    else
        echo "Warning: Failed to restart tcpser service"
        exit 1
    fi
else
    echo "Error: Failed to update configuration"
    exit 1
fi
EOF

if sudo chmod 755 /usr/local/bin/pimodem-baud; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating ppp user..."
if { id ppp > /dev/null 2>&1 || sudo useradd -m ppp > /dev/null 2>&1; } \
    && sudo usermod -aG dip ppp > /dev/null 2>&1 \
    && sudo usermod -s /usr/sbin/pppd ppp > /dev/null 2>&1 \
    && sudo touch /home/ppp/.hushlogin > /dev/null 2>&1 \
    && sudo loginctl enable-linger pi ppp; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Creating pppd configuration..."
[ -e /etc/ppp/options.orig ] || sudo mv /etc/ppp/options /etc/ppp/options.orig > /dev/null 2>&1
[ -e /etc/ppp/pap-secrets.orig ] || sudo mv /etc/ppp/pap-secrets /etc/ppp/pap-secrets.orig > /dev/null 2>&1

sudo tee /etc/ppp/options > /dev/null << 'EOF'
# We will be doing PPP over Telnet - disable serial control.
local

# Terminate connection if remote side stops responding.
lcp-echo-interval 30
lcp-echo-failure 4

# Debug adds a lot of detail into the system logs regarding PPP negotiation.
# This is helpful in debugging client issues.
#debug

# IP addresses to use in local:remote format. We use NAT to share
# the Wi-Fi connection, make sure these are outside of your real subnet.
192.168.192.1:192.168.192.2

# Other sensible options
asyncmap 0
passive
noipx
noauth
EOF

sudo tee /etc/ppp/pap-secrets > /dev/null << 'EOF'
# Allow any username/password
* * "" *
EOF

sudo tee /etc/xinetd.d/pppd > /dev/null << 'EOF'
service pppd
{
    type        = UNLISTED
    flags       = REUSE
    socket_type = stream
    wait        = no
    user        = root
    server      = /usr/sbin/in.telnetd
    server_args = -h -L /usr/local/bin/ppplogin
    disable     = no
    bind        = 127.0.0.1
    port        = 2323
}
EOF

sudo tee /usr/local/bin/ppplogin > /dev/null << 'EOF'
#!/bin/bash
/bin/login -f ppp
EOF

if sudo chmod 755 /usr/local/bin/ppplogin \
    && sudo systemctl enable xinetd > /dev/null 2>&1 \
    && sudo systemctl restart xinetd > /dev/null 2>&1; then
    echo "Done"
else
    echo "Failed"
    exit 1
fi

echo -n "Verifying services..."
if systemctl is-active --quiet tcpser && systemctl is-active --quiet xinetd; then
    echo "Done"
else
    echo "Warning: Some services may not be running"
fi

echo
echo "PiModem setup complete!"
echo
echo "Default baud rate: 9600 (good for most retro systems)"
echo
echo "To change baud rate if needed/desired:"
echo "  pimodem-baud <rate>"
echo
echo "Examples:"
echo "  pimodem-baud 2400    # Change to 2400 baud"
echo "  pimodem-baud 19200   # Change to 19200 baud"
echo "  pimodem-baud         # Show current setting"
echo
echo "Common rates: 300, 1200, 2400, 9600, 19200, 38400"
echo
echo "Check status anytime: sudo systemctl status tcpser"
echo
