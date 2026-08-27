# Oracle Patch Guard tree hash V2

## Doel en identiteit

`OPG_TREE_HASH_V2` bindt een uitgepakte patchboom aan inhoud en relatieve
bestandsnamen. De absolute bron- of stagingdirectory maakt geen deel uit van de
hash. Dezelfde reguliere bestanden onder twee verschillende roots leveren dus
dezelfde tree-hash op.

V2 vervangt V1 niet stilzwijgend. Iedere artifact- en run-manifestatie vermeldt
expliciet `tree_hash_format=OPG_TREE_HASH_V2`; V1 en V2 zijn verschillende
identiteiten en mogen niet onderling worden vergeleken.

## Toegestane objecten

- Directories worden alleen gebruikt om te traverseren en worden niet gehasht.
- Alleen reguliere bestanden zijn toegestaan.
- Symlinks, hardlinks met link count groter dan 1, sockets, devices, FIFO's en
  andere speciale objecten leiden fail-closed tot een fout.
- Relatieve paden zijn niet leeg, beginnen niet met `/` en bevatten geen `.`-
  of `..`-componenten. NUL kan niet voorkomen in een Unix-bestandsnaam.

## Canonieke byte-stream

Alle sortering en encoding gebeurt byte-georiënteerd, equivalent aan
`LC_ALL=C`. Paden worden als de oorspronkelijke filesystem-bytes verwerkt; er
is geen Unicode-normalisatie.

De SHA256 wordt berekend over deze stream:

1. exact de ASCII-header `OPG_TREE_HASH_V2` gevolgd door één NUL-byte;
2. voor ieder bestand, gesorteerd op de ruwe bytes van het relatieve pad, één
   record:

   `F\0<size-decimal>\0<file-sha256-lowerhex>\0<path-length-decimal>\0<path-bytes>`

`size-decimal` en `path-length-decimal` bevatten uitsluitend ASCII-cijfers en
geen voorloopnullen (behalve de waarde `0`). De padlengte maakt de records
ondubbelzinnig; er volgt geen newline of extra recordseparator.

## Mutatiedetectie

De implementatie:

1. inventariseert de volledige boom zonder symlinks te volgen;
2. opent ieder bestand met `O_NOFOLLOW` waar het platform dat ondersteunt;
3. vergelijkt type, device, inode, link count, grootte, mtime en ctime vóór en
   na het lezen;
4. inventariseert de boom opnieuw en vereist exact dezelfde entries en
   metadata.

Iedere afwijking is een fout; er wordt nooit een hash voor een mogelijk gemengde
toestand geaccepteerd.

## Golden vectors

De uitvoer van `tests/test_tree_hash_v2.sh` is normatief. De vaste waarden
worden na implementatie hieronder ingevuld en door de test bewaakt:

- lege boom: `fc7148770e90462c53b00b50bf17c592601347ca8413c60df09caf6722e9d597`
- `a.txt` met bytes `abc`: `5d6926712e919b727b504ee586bd9280834355e7d804d115102c3f09641be616`
- bestanden `a|b`=`x` en `line\nbreak`=`y`:
  `0e3d6c0065671517043627886bff3b8f7b79962e85211c76e2e5d41c2b266c5b`
