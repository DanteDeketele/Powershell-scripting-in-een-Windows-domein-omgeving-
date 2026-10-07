# Opdracht: Powershell in een Windows domein omgeving

Waarover gaat deze opdracht?
Je automatiseert een aantal procedure tijdens het opzetten van een Windows domein met twee DC's, een memberserver MS en een Windows 11 client.

## Benodigdheden

Je hebt toegang tot je eigen virtuele Windows omgeving, zie email.
Richtlijnen
Gebruik van AI. Je mag AI gebruiken om begrippen te laten uitleggen, je tekst na te lezen of structuur aan te brengen. Je mag AI niet gebruiken om je meetwaarden, je verklaringen of je advies te laten schrijven: dat is exact wat beoordeeld wordt. Vermeld onderaan je rapport kort waarvoor je AI hebt ingezet.
 
## Opbouw van de opdracht

1.	DHCP redundantie

    -	Op DC1 is er reeds een DHCP server actief. Je dient DC2 via een PS-script als replicatiepartner te configureren.
    -	Test op de DHCP service + tools zijn geïnstalleerd op de DC2.
    -	Nog niet geïnstalleerd, installatie + authoriseer de DHCP server in AD op DC2.
    -	Zet het replication partnership op.
    -	Zorg dat de DHCP server optie ook gemaakt worden op DC2, maar wissel de DNS servers van volgorde.
    -	Zorg dat de warning verdwijnt in de server manager op DC2, inzake het authoriseren in AD.

2.	Maak een PS-script om DHCP reservaties te maken in DC1 en zorg dat ze direct gerepliceerd worden. 

    -	Werk met een excel-sheet met de nodige kolommen als input.


3.	Maak een aantal nieuw gebruikers aan op DC1.
    -	Zorg dat de home share al bestaat op MS met de correcte rechten.
        -	Share rechten: Everyone - full control
        -	NTFS rechten: Administrator - full control en Authenticated Users - Read only for this folder only.
    -	Zet het gebruikersobject in de juiste OU en voeg het toe in de juiste Windows groep.
    -	Maak gebruik van een excel-sheet als input file met de nodige velden.

4.	Voeg een extra UPN-suffix toe op domein niveau en maak deze de default voor alle gebruikers binnen de bedrijfs-OU (dus niet op het ganse domein). D.w.z. pas alle bestaande gebruikers aan.

5.	Maak een fictieve OU-structuur op basis van een zelfgekozen organigram dat je vindt op Internet als bijvoorbeeld.

## Wat lever je in?
Rapport
-	1 ZIP-bestand
-	Structuur: Volg de deelopdrachten.
-	Bestandsnaam: Familienaam_Voornaam_PS_Windows_Domein.zip
-	Bronnenlijst achteraan, met links en datum van raadpleging. Vermeld ook kort je AI-gebruik.


## Bronnen en hulpmiddelen


