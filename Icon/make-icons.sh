#!/bin/bash
# Buduje trzy warianty ikony z source.svg i wpina je do katalogu zasobow.
#
# Dlaczego przez raster, a nie czysto w SVG: source.svg pochodzi z trace'owania
# rastra i tlo oraz kremowe partie ptaka siedza w JEDNEJ sciezce. Usuniecie tla
# w SVG zabiera razem z nim wypelnienie ptaka. Prostsza i pewniejsza droga to
# wyrenderowac oryginal w duzej rozdzielczosci i wyciac tlo flood fillem od rogow
# - sylwetka jest domknieta czarnym obrysem, wiec wypelnienie nie przecieka.
set -euo pipefail
cd "$(dirname "$0")"

SET=../MajorLite/Assets.xcassets/AppIcon.appiconset

magick source.svg -resize 2048x2048 -alpha set /tmp/mj-big.png
magick /tmp/mj-big.png -fuzz 12% -fill none \
  -floodfill +0+0 '#fafbed' -floodfill +2047+0 '#fafbed' \
  -floodfill +0+2047 '#fafbed' -floodfill +2047+2047 '#fafbed' /tmp/mj-cut.png
magick /tmp/mj-cut.png -trim +repage -resize 880x880 \
  -background none -gravity center -extent 1024x1024 art.png

# jasna: nieprzezroczysta (wymog App Store), tlo jak w oryginale
magick -size 1024x1024 xc:'#FAFBED' art.png -composite -alpha off icon-light.png
# ciemna: przezroczysta, system podklada wlasne tlo
cp art.png icon-dark.png
# tinted: skala szarosci, system barwi wedlug jasnosci
magick art.png -colorspace Gray -alpha on icon-tinted.png

cp icon-light.png icon-dark.png icon-tinted.png "$SET/"
rm -f /tmp/mj-big.png /tmp/mj-cut.png
echo "gotowe - trzy warianty w $SET"
