#!/usr/bin/env python3
"""
Vodafone TV (PT) -> Kaltura TVPaaS, partner 3038.
Fetches the channel line-up exactly as the Android app com.vodafone.vtv.pt
3.0.27 presents it.

build with help of AI
License GPL V3

Usage
    VTV_KS='<ks>' ./vtv_channels.py            # linear line-up, channels.txt format (default)
    VTV_KS='<ks>' ./vtv_channels.py linear     # same as above
    VTV_KS='<ks>' ./vtv_channels.py channels   # every Kaltura channel (linear + genre rails + VOD cats)
    VTV_KS='<ks>' ./vtv_channels.py all        # both sections in one file
    VTV_KS='<ks>' ./vtv_channels.py get 100356082  # channel/action/get, raw JSON
    VTV_KS='<ks>' ./vtv_channels.py raw        # raw JSON of channel/action/list
    VTV_KS='<ks>' ./vtv_channels.py session    # ks lifetime (exit 2 if expired)

Output format (default / linear) - tab separated, sorted ascending by
channel id:

    <epg_channel_id>\t<name>\t<logo_url>

Environment
    VTV_KS       Kaltura session (required)
    VTV_OUT      write to file instead of stdout
    VTV_GW       Kaltura host, default 3038.api-vfp2.ott.kaltura.com
    VTV_API      apiVersion, default 5.2
    LOGO_W/LOGO_H logo pixel size, default 240x150
    SORT=0          keep the raw API pager order instead of sorting by channel id
    HEADER=0        omit the leading comment header
    SOURCESTAMP=YYYY/MM/DD   override the "Last Updated" date (default: today, UTC)
    PAGE_SIZE    pager size, default 50

Getting a ks
------------
The app login (apigw.pt.vtv.vodafone.com/.../authentication/v1/credentials)
needs a `vtv-authentication` Nagra DAS device-attestation header produced by the
device DRM/TEE stack, so it cannot be done from curl -- omitting it returns
apigw-10001 MANDATORY_FIELDS and a bogus one returns RF-NagraDASAuthenticateFault.
Capture the ks from a real device instead: it is the `ks` field of the JSON body
of every POST to the Phoenix gateway, and base64-decodes to "v2|3038|<session>".
The app does not pin certificates (app.hs.c.p=false), so a mitmproxy user CA
works.
Also the web site also deliveres the ks key after login, that may be easier to 
get. Expired ks keys also seems to still work, but to be confirmed

Why this host
-------------
The Vodafone APIGW adds its own session layer and rejects even a valid ks
(apigw-11001 "Invalid request").  The Kaltura host validates the same ks
natively.  The `channels` service (channels/action/*) is registered on the
APIGW only, not here -- use `channel/action/*`.

Logo URLs
---------
Logos come from the `images` array, picking imageTypeId 83 (16:10, the TV
channel logo type) and rewriting width/height to 240x150.  The GetImage URL is
a template, so any size works from the same entry_id/version.
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

GW = os.environ.get("VTV_GW", "3038.api-vfp2.ott.kaltura.com")
API = os.environ.get("VTV_API", "5.2")
SIZE = int(os.environ.get("PAGE_SIZE", "50"))
OUT = os.environ.get("VTV_OUT")
KS = os.environ.get("VTV_KS")
LOGO_W = os.environ.get("LOGO_W", "240")
LOGO_H = os.environ.get("LOGO_H", "150")
LOGO_TYPE_ID = int(os.environ.get("LOGO_TYPE_ID", "83"))
SORT = int(os.environ.get("SORT", "1"))
# write the channels.txt header (comment keys + Last Updated date)
HEADER_ON = int(os.environ.get("HEADER", "1"))
SVC = "https://%s/api_v3/service" % GW

# linear TV channels, i.e. the actual line-up (asset_type 444)
LINEAR_KSQL = "(and (or asset_type='444'))"
EPG_RE = re.compile(r"epg_channel_id='(\d+)'")

if not KS:
    sys.exit("VTV_KS is required - see the docstring")


def post(path, extra):
    req = {"ks": KS, "apiVersion": API, "language": "*"}
    req.update(extra)
    r = urllib.request.Request(
        "%s/%s" % (SVC, path),
        data=json.dumps(req).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(r, timeout=60) as f:
            res = json.load(f)
    except urllib.error.HTTPError as e:
        sys.exit("!! HTTP %s from %s" % (e.code, path))
    err = res.get("result", {}).get("error")
    if err:
        hint = ""
        if str(err.get("code")) == "500016":
            hint = (
                "\n!! This ks has been invalidated server-side.\n"
                "   Note that 'asset/action/list' (the default 'linear' mode) may\n"
                "   still work - Kaltura does not re-check the session there.\n"
                "   Opening the app again / logging in issues a new session and\n"
                "   kills the old one, which is the usual cause."
            )
        sys.exit("!! %s -> %s%s" % (path, json.dumps(err), hint))
    return res.get("result", {})


def walk(path, extra):
    """Page through <service>.action.list, yielding each object."""
    page = got = 0
    total = 1
    while got < total:
        page += 1
        pager = {"objectType": "KalturaFilterPager",
                 "pageSize": SIZE, "pageIndex": page}
        res = post(path, dict(extra, pager=pager))
        objs = res.get("objects") or []
        total = res.get("totalCount", 0)
        for o in objs:
            yield o
        got += len(objs)
        print("# %s: %d/%d" % (path, got, total), file=sys.stderr)
        if not objs:
            return


def logo_url(asset):
    """The 16:9-ish TV channel logo, resized to LOGO_W x LOGO_H."""
    for im in asset.get("images") or []:
        if im.get("imageTypeId") == LOGO_TYPE_ID:
            # GetImage URLs are templates:
            #   .../entry_id/X/version/N[/width/W/height/H][/quality/Q]
            # strip any size/quality args, then append the ones we want.
            url = re.sub(r"/(width|height|quality)/\d+", "", im["url"])
            return "%s/width/%s/height/%s/quality/100" % (url, LOGO_W, LOGO_H)
    return ""


def q(name):
    """Channel name, unquoted.  Quotes are stripped so the field stays clean
    TSV (a stray double quote in a name would otherwise break it)."""
    return (name or "").replace('"', "").strip()


def stamp(e):
    return datetime.datetime.fromtimestamp(e, datetime.timezone.utc)\
        .strftime("%Y-%m-%d %H:%M:%S UTC")


def session():
    """Report the ks lifetime via session/action/get."""
    r = post("session/action/get", {})
    created, expiry = r.get("createDate", 0), r.get("expiry", 0)
    now = int(time.time())
    print("partner   : %s" % r.get("partnerId"))
    print("userId    : %s" % r.get("userId"))
    print("created   : %s" % stamp(created))
    print("expiry    : %s" % stamp(expiry))
    print("lifetime  : %.1f h" % ((expiry - created) / 3600.0))
    print("remaining : %.2f h%s" % ((expiry - now) / 3600.0,
                                    "  (EXPIRED)" if expiry - now <= 0 else ""))
    print("refresh at: %s   (app rule: 95%% of remaining, min 1h before expiry)"
          % stamp(now + min((expiry - now) * 0.95, expiry - now - 3600)))
    return expiry - now <= 0


def linear():
    """The real line-up, in channels.txt format.

    `externalIds` is the epg_channel_id used in channels.txt (SIC -> "2670").
    `externalId`/`externalEpgIngestId` are different ids (SIC -> "390") and
    `id` is the Kaltura asset id.

    The API returns rows in pager order (roughly newest id first), but the
    official channels.txt is sorted ascending by channel id, so we buffer and
    sort before emitting.  SORT=0 keeps the raw API order.
    """
    rows = []
    for o in walk("asset/action/list",
                  {"filter": {"objectType": "KalturaSearchAssetFilter",
                              "kSql": LINEAR_KSQL}}):
        cid = o.get("externalIds") or o["id"]
        rows.append((cid, "%s\t%s\t%s" % (cid, q(o.get("name") or ""),
                                          logo_url(o))))
    if SORT:
        rows.sort(key=lambda r: int(r[0]))
    for _, line in rows:
        yield line


def channels():
    """Every KalturaDynamicChannel: linear channels, per-channel genre rails and
    VOD categories, as id / epg_channel_id / name."""
    for o in walk("channel/action/list", {}):
        m = EPG_RE.search(o.get("kSql") or "")
        yield "%s\t%s\t%s" % (o["id"], m.group(1) if m else "",
                              q(o.get("name") or ""))


HEADER = """## Comemnt out keys
#- -> removed channel
#d -> dupe channel, SD vs HD
## Last Updated: {date}

## From app
"""


def header():
    """The channels.txt header.  Date is today (UTC) unless SOURCESTAMP is set,
    so re-running the script keeps the file's 'Last Updated' current."""
    stamp = os.environ.get("SOURCESTAMP") or \
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y/%m/%d")
    return HEADER.format(date=stamp)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "linear"
    dest = open(OUT, "w") if OUT else sys.stdout
    if HEADER_ON:
        dest.write(header())

    if mode == "raw":
        json.dump(post("channel/action/list", {}), dest, indent=1)
        return

    if mode == "session":
        sys.exit(2 if session() else 0)

    if mode == "get":
        if len(sys.argv) < 3:
            sys.exit("usage: vtv_channels.py get <channelId>")
        json.dump(post("channel/action/get", {"id": int(sys.argv[2])}),
                  dest, indent=1)
        return

    if mode == "linear":
        rows = linear()
    elif mode == "channels":
        rows = channels()
    elif mode == "all":
        dest.write("# --- linear line-up: epg_channel_id\\tname\\tlogo ---\n")
        for r in linear():
            dest.write(r + "\n")
        dest.write("# --- all Kaltura channels: id\\tepg_channel_id\\tname ---\n")
        rows = channels()
    else:
        sys.exit("unknown mode: %s "
                 "(linear|channels|all|get|raw|session)" % mode)

    for r in rows:
        dest.write(r + "\n")


main()
