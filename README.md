# PowerShell in een Windows domein omgeving

De bestanden staan hieronder in de volgorde waarin de scripts uitgevoerd worden. Alle scripts draaien op WIN00-DC1, met de CSV-bestanden in `C:\Users\Administrator\Documents`.

## Stap 1: DHCP redundantie (deel 1)

- `scripts/dhcp_redundancy.ps1`: configureert DC2 als DHCP-replicatiepartner.
- `scripts/remove_dhcp.ps1`: maakt deel 1 ongedaan om het opnieuw te testen.
- `dhcp_redundancy_1st_output.txt`, `dhcp_redundancy_2nd_run_output.txt`, `dhcp_redundancy_3rd_run_output.txt`, `dhcp_redundancy_4_output.txt`: logs van `dhcp_redundancy.ps1`.
- `remove_dhcp_output.txt`: log van `remove_dhcp.ps1`.
- `screenshot_from_dc2.png`: Server Manager op DC2.

## Stap 2: DHCP reservaties (deel 2)

- `scripts/dhcp_reservations_from_csv.ps1`: maakt de reservaties aan en repliceert ze naar DC2.
- `reservaties.csv`: input met de reservaties.
- `dhcp_reservation_from_csv_1_output.txt`, `dhcp_reservation_from_csv_2_output.txt`: logs.

## Stap 3: Gebruikers en home share (deel 3)

- `scripts/csv_to_users.ps1`: zet de home share op MS en maakt de OU's, groepen en gebruikers aan.
- `gebruikers.csv`: input met de gebruikers.
- `csv_to_users_output_twice.txt`: log.

## Stap 4: OU-structuur (deel 5)

- `scripts/ou_from_csv.ps1`: maakt de OU-structuur aan onder `Bedrijf`.
- `ou_structuur.csv`: input met de OU-structuur.
- `ou_from_csv_twice.txt`: log.

## Stap 5: UPN-suffix (deel 4)

- `scripts/upn_suffix_bedrijfsou.ps1`: voegt de UPN-suffix toe en past de gebruikers onder `Bedrijf` aan.
- `upn_output_twice.txt`: log.

## Overige bestanden

- `Assignment.md`: de opdracht.
- `output1.txt`, `output2.txt`: logs van oudere scriptversies.

## AI-gebruik

De scripts zijn geschreven en aangepast met hulp van AI: eerst Gemini, daarna GitHub Copilot agent en als laatste Claude Code. Ik heb ze zelf uitgevoerd en getest op mijn virtuele omgeving.
