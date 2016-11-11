#!/bin/bash
# v1.0 higuita@gmx.net 2016/11/10
# License GPL V3

# all urls/api taken from https://tvnetvoz.vodafone.pt/sempre-consigo/guia-tv
# the service is very fast and reliable, much better than the very weak
# NOS page and more stable than MEO webservice

# Sadly vodafone didn't help in any way, even after several attempts to have
# then cooperate with me

# TODO:
# - support range > 1
# - support offset
# - port to perl and submit to xmltv
# - expand the xmltv

if [ -z $1 ]; then
	day=0
else
	day=$1
fi

tmpd=$( mktemp -d  /tmp/vdp.pt-xmltv.XXXXXX )

isodate=$(date -d +${day}day  +%Y-%m-%d)
sdate=$(date -d +${day}day  +%Y%m%d)
edate=$(date -d +$((day+1))day  +%Y%m%d)


# Grab current channel list and IDs
curl -s  https://tvnetvoz.vodafone.pt/sempre-consigo/datajson/epg/channels.jsp | \
	sed 's/{/\n{/g' | \
	sed -nr 's/.*"id":"([^"]*)".*,"name":"([^"]*).*"callLetter":"([^"]*).*/\1	\3	\2/gp' | \
	sort -n >${tmpd}/list

# channel IDs to request the json with the info from the web api
cids=$( cat ${tmpd}/list | sed -r 's/^([0-9]*).*/\1,/g' | sed -r ':a ; N ; $!ba ; s/\n//g ; s/,$//g  ' )

# Magic, one request and get all the needed info in json format
curl -s 'https://tvnetvoz.vodafone.pt/sempre-consigo/epg.do?action=getPrograms' \
	-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
	--data "chanids=${cids}&day=${isodate}" > ${tmpd}/json

# Lets convert the json to xmltv
echo '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv source-info-url="https://store.services.sapo.pt/en/cat/catalog/other/meo-epg/technical-description" source-info-name="Vodafone EPG Service" generator-info-name="XMLTV/$Id: tv_grab_pt_vodafone,v 1.0 2016/11/15 00:00:00 higuita Exp $" generator-info-url="http://www.xmltv.org/">
' > ${tmpd}/xmltv

# create the channel id list. Remove bad characters for channel id
cat ${tmpd}/list | sed ' s/[+!&]//g ' | awk -F"	"  '
	{ channel= gensub(/ /,"","g",tolower($2))
	  id = $1
	  print "  <channel id=\"" channel ".tv.vodafone.pt\">\n\
    <display-name lang=\"pt\">"$3"</display-name>\n\
    <icon src=\"https://tvnetvoz.vodafone.pt/sempre-consigo/imgs?action=logo_channel_tablet_details&amp;chanid=" id "&amp;mime=true&amp;no_default=false\" />\n\
  </channel>" }
	' >> ${tmpd}/xmltv

# clean bad characters for xml and extract the info from the json to the xmltv
# yes, i like awk! :)
cat ${tmpd}/json | \
 	sed '  s/CAC & PESCA/CACPESCA/g ; s/&/&amp;/g ; s,\\/,/,g; s/\\u\([0-9]\{4\}\)/\&#x\1;/g  ; s//«/g ; s//»/g ; s/</&lt;/g ; s/>/&gt;/g' | \
	awk -v sdate=${sdate} -v edate=${edate} '

	BEGIN			{ RS=",\"|\n|{|}" ; FS="\"" }
	$2 ~ /callLetter/	{ channel=gensub(/[ +!&]/, "", "g", tolower($4)) }
	$2 ~ /startTime/	{ start=sprintf("%04d",gensub(/:/,"","g",$4))  }
	$1 ~ /endTime/		{ end=sprintf("%04d",gensub(/:/,"","g",$3)) }
	$1 ~ /programTitle/	{ title=$3 ;
				  if ($4 ~/Ep\.[0-9]/) {
					ep=gensub(/.*Ep\.([0-9]*).*/,"\\1","g",$4) }
				  if ($4 ~/^T[0-9]/) {
					t=gensub(/T([0-9]*).*/,"\\1","g",$4)
				  } else {
					for(i=6;i<=NF;i++){ title=title ":" $i } } }
	$1 ~ /programDetails/	{ desc=$3 ; for(i=5;i<=NF;i++){title=title ":" $i } }
	$1 ~ /date/		{ date=gensub(/([0-9]*)-([0-9]*)-([0-9]*)/,"\\3\\2\\1","g",$3)
				  if ( end < start) {
				  	if ( date < sdate ) {
						date_end=sdate }
					else { date_end=edate } }
				  else {
					date_end=date}
				  print "  <programme start=\"" date start "00 +0000\" stop=\"" date_end end "00 +0000\" channel=\"" channel ".tv.vodafone.pt\">\n\
    <title lang=\"pt\">" title "</title>\n\
    <desc lang=\"pt\">" desc "</desc>";
				  if ( length(t) > 0 ) {
					print "    <episode-num system=\"xmltv_ns\">"t" . "ep" .</episode-num>"
				  };
				  print "  </programme>" ;
				  start="" ; end="" ; title=""; desc=""; t=""; ep="" }
' >> ${tmpd}/xmltv
echo "</tv>" >> ${tmpd}/xmltv

# output the result
cat ${tmpd}/xmltv

# Cleanup, comment this one to help debug problems
rm -r ${tmpd}
