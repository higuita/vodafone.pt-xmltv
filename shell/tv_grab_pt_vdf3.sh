#!/bin/bash -e
# v1.0 higuita@gmx.net 2019/10/25
# License GPL V3
# as the Vodafone tvguide site used in the previous script was disabled,
# lets try to use the app webservice as a quick workaround.
# second attempt to alternative api as it look faster and easier

# how many days to grab
days=1


rm -rf /tmp/vodafone-xml || true
mkdir -p /tmp/vodafone-xml

# get channel list and build xmltv channel list
curl -s 'https://web.ott-red.vodafone.pt/ott3_webapp/v1/channels' >/tmp/vodafone-xml/channels.json

cat<<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv source-info-url="https://www.vodafone.pt/pacotes/televisao/em-todos-ecras.html#computador" source-info-name="Vodafone TV app EPG Service" source-data-url="https://web.ott-red.vodafone.pt/ott3_webapp/" generator-info-name="XMLTV/0" generator-info-url="http://www.xmltv.org/">
EOF

jq '.data[]' /tmp/vodafone-xml/channels.json | \
  sed 's/&/&amp;/g' | \
  awk -F'"' '
	$2 == "id"	{
			  if (NR>4) { print icon; print "  </channel>" }
			  print "  <channel id=\""gensub(/[^a-z0-9]/,"","g",gensub(/&amp;/,"","g",tolower($4)))".tv.vodafone.pt\">"
			  display_id="    <display-name lang=\"pt\">"$4"</display-name>"
			  id=$4
			}
	$2 == "name"	{ print "    <display-name lang=\"pt\">"$4"</display-name>"
			  if (id!=$4) { print display_id }
			}
	$2 == "logo"	{ icon="    <icon src=\""$4"\"/>" }
	END		{
			  print icon
			  print "  </channel>"
			}
  '

# get epg data for each channel
for i in $( jq '.data[].id' /tmp/vodafone-xml/channels.json | sed 's/ /%20/g' ); do
	shortid=$( echo $i | sed 's/%20//g' | tr [A-Z] [a-z] |  sed -r 's/&amp;//g; s/[^a-z0-9]//g' )
	curl -s "https://web.ott-red.vodafone.pt/ott3_webapp/v1.5/programs/grids/${i//\"}/$days" > /tmp/vodafone-xml/epgdata.json
	cat /tmp/vodafone-xml/epgdata.json | \
		sed 's/&/&amp;/g' | \
		jq '.data[]' | \
		awk -v shortid="$shortid" '
		BEGIN			{ FS="\"" }
#					{ print "++" $0 "++" $4 "++"}
		$2 == "guid"		{ title=""; subtitle=""; desc=""; nseason=""; season=""; nepisode=""; episode=""; start=""; end=""}
		$2 == "title"		{ title="    <title lang=\"pt\">"$4"</title>" }
		$2 == "fullTitle"	{ subtitle="    <sub-title lang=\"pt\">"$4"</sub-title>" }
		$2 == "description"	{ desc="    <desc lang=\"pt\">"$4"</desc>" }
		$2 == "logo"		{ logo="    <icon src=\""$4"\"/>" }
		$2 == "duration"	{ duration="    <length units=\"seconds\">"gensub(/: ([0-9]*),/,"\\1","g",$3)"</length>" }
		$2 == "category"	{ category="    <category lang=\"en\">"$4"</category>" }
		$2 == "season"		{
					  nseason=gensub(/: ([0-9]*),/,"\\1","g",$3)
					  if (nseason == 0) { nseason=1 }
					}
		$2 == "seasonLabel"	{ season=$4 }
		$2 == "episode"		{
					  nepisode=gensub(/: ([0-9]*),/,"\\1","g",$3)
					  if (nepisode > 0) { xmltv_ns="    <episode-num system=\"xmltv_ns\">"nseason-1"."gensub(/: ([0-9]*),/,"\\1","g",$3)-1".</episode-num>" }
					}
		$2 == "episodeLabel"	{
					  if (nepisode > 0) { onscreen="    <episode-num system=\"onscreen\">"season" "$4"</episode-num>" }
					}
		$2 == "startTime"	{ start=strftime("%Y%m%d%H%M%S", $4) }
		$2 == "endTime"		{ end=strftime("%Y%m%d%H%M%S", $4) }
		$2 == "isPlayable"	{
					  print "  <programme start=\""start" +0100\" stop=\""end" +0100\" channel=\""shortid".tv.vodafone.pt\">"
					  print title
					  print subtitle
					  print desc
					  print category
					  print duration
					  print logo
					  print xmltv_ns
					  print onscreen
					  print "  </programme>"
					}
	'
done
echo "</tv>"

rm -rf /tmp/vodafone-xml
