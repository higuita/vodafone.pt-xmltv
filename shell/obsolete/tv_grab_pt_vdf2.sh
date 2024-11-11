#!/bin/bash -e
# v1.0 higuita@gmx.net 2019/08/24
# v1.1 higuita@gmx.net 2019/10/24
# License GPL V3

# as the Vodafone tvguide site used in the previous script was disabled,
# lets try to use the app webservice as a quick workaround.
# As it require query for eash channel and parse each egp, its much slower
# will try to find better endpoints, but for now, better than nothing

get_data(){
	curl -sf \
		-H "Content-Type: application/xml" \
		-d "$*" \
		-H "User-Agent: Vodafone TV Net Voz/2.1.2/SMARTANDROID QlEgQlEgQVFVQVJJUyAzLjUgNC4yLjI=" \
		-X POST \
		http://vasp.vodafone.pt/ott/companiontv.do -o /tmp/vodafone-xml/data.xml
}

extract(){
	sed -nr "/$1/ s/.*>(.*)<.*/\1/gp"
}

get_channels(){
	post='<body><getChannelData></getChannelData></body>'
	get_data $post
}

get_epg(){
	post='
<body>
<getEPGData>
<timezone>WET</timezone>
<currentTime>'$now'</currentTime>
<epgStartTime>'$lasthour'</epgStartTime>
<epgEndTime>'$nextday'</epgEndTime>
'$*'
</getEPGData></body>'

	get_data $post
}

break(){
	cat /tmp/vodafone-xml/data.xml | awk -v separator="$1" -v ext="$2" '
		BEGIN	{ RS=separator}
		NR == 1 { next }
			{ a++; print > "/tmp/vodafone-xml/"a"."ext }
		'
}

# MAIN
test -e /tmp/vodafone-xml && rm -rf /tmp/vodafone-xml
mkdir /tmp/vodafone-xml
now=$( date +%s)
lasthour=$( date -d -1hour +%s)
nextday=$(date -d +1day +%s)

get_channels
break "<channel>" tv

# start xmltv outpug

# Iterate channels
for i in /tmp/vodafone-xml/*.tv; do
	id="$(    cat $i  | extract channelId )"
	name="$(  cat $i  | extract channelName )"
	img="$(   cat $i  | extract channelLogoLarge )"
	shortid=$( echo "$name" | tr [A-Z] [a-z] | sed -r 's/[^a-z0-9]//g')


	echo '  <channel id="'$shortid'.tv.vodafone.pt">
    <display-name lang="pt">'$name'</display-name>
    <display-name lang="pt">'$id'</display-name>
    <icon src="'$img'"/>
  </channel>' >> /tmp/vodafone-xml/channels.xml

	xml_channel="${xml_channel} <channelId>$id</channelId>
"
done
get_epg "${xml_channel}"

awk -v shortid=$shortid '
	BEGIN                   { RS="<epgData>"; FS="[<>]"}
	NR == 1                 { next }
	/channelId/		{ shortid=gensub(/[^a-z0-9]/, "", "g", tolower($3) ) }
	/programName/           { title=$23 ; season=gensub(/.*[: ]T([0-9]+) ?.*/,"\\1","g",title); ep=gensub(/.*[: ]Ep\.([0-9]+)/,"\\1","g",title) }
	/programStartTime/	{ start=strftime("%Y%m%d%H%M%S", $15) }
	/programEndTime/        { end=strftime("%Y%m%d%H%M%S", $19)   }
	/epgData/               {
				  print "  <programme start=\""start" +0100\" stop=\""end" +0100\" channel=\""shortid".tv.vodafone.pt\">"
				  print "    <title lang=\"pt\">"title"</title>"
				  #if (desc) { print"    <desc lang=\"pt\">"desc"</desc>" }
				  #if (category) { print "    <category lang=\"pt\">"category"</category>" }
				  if (season == title ) { season=1 }
				  if (ep != title) {
					print "    <episode-num system=\"onscreen\">S"season" E"ep".</episode-num>"
					print "    <episode-num system=\"xmltv_ns\">"season-1"."ep-1".</episode-num>"
					}
				  print "  </programme>"
				}
	' /tmp/vodafone-xml/data.xml > /tmp/vodafone-xml/epg.xml

cat<<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv source-info-url="https://www.vodafone.pt/pacotes/televisao/em-todos-ecras.html"
 source-info-name="Vodafone TV app EPG Service"
 source-data-url="http://vasp.vodafone.pt/ott/companiontv.do"
 generator-info-name="XMLTV/0" generator-info-url="http://www.xmltv.org/">
EOF
cat /tmp/vodafone-xml/channels.xml /tmp/vodafone-xml/epg.xml
echo "</tv>"

rm -rf /tmp/vodafone-xml
