# Ikona

Jaskółka w stylu old-school tattoo. `source.svg` to grafika dostarczona przez
użytkownika (wektor z trace'owania rastra, 215 ścieżek).

`./make-icons.sh` buduje trzy warianty i wpina je do katalogu zasobów:

| Plik | Wariant | Tło |
|---|---|---|
| `icon-light.png` | jasny (domyślny) | kremowe `#FAFBED`, bez kanału alfa |
| `icon-dark.png` | ciemny | przezroczyste |
| `icon-tinted.png` | przygaszony | przezroczyste, skala szarości |

`art.png` to półprodukt — ptak z przezroczystym tłem, wyśrodkowany na 1024×1024
z marginesem 12%.

`render.swift` rasteryzuje SVG przez WebKit. Nie jest używany w tym potoku
(ImageMagick radzi sobie z tą grafiką lepiej), ale przydaje się do SVG
korzystających z obrysów i dziedziczenia atrybutów, które wewnętrzny renderer
ImageMagicka gubi.
