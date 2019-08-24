#!/bin/bash -e
# v1.0 higuita@gmx.net 2019/08/24
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
<channelId>'$*'</channelId>
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
cat<<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv source-info-url="https://tvnetvoz.vodafone.pt/sempre-consigo/guia-tv" source-info-name="EPG Service for Vodafone" generator-info-name="XMLTV/0" generator-info-url="http://www.xmltv.org/">
EOF

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
  </channel>'

	rm /tmp/vodafone-xml/*.epg || true
	get_epg "$id"
	break "<epgData>" epg

	# iterate epg programs
	for a in /tmp/vodafone-xml/*.epg ; do
		title="$( cat $a | extract programName )"
		episode=$( echo "$title" | sed -nr 's/.*:((T[0-9]+ )?Ep\..*)/\1/gp')
		end=$(   cat $a | extract programEndTime )
		start=$( cat $a | extract programStartTime )


		echo '  <programme start="'$( date -d @$start +%Y%m%d%H%M%S)' +0100" stop="'$( date -d @$end +%Y%m%d%H%M%S)' +0100" channel="'$shortid'.tv.vodafone.pt">
    <title lang="pt">'$title'</title>
    <desc lang="pt">'$desc'</desc>
    <category lang="pt">'$category'</category>
    <episode-num system="onscreen">'$episode'</episode-num>
  </programme>'
	done
done
echo "</tv>"
rm -rf /tmp/vodafone-xml
