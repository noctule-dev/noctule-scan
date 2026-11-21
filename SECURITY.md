# Security policy

## Reporting a vulnerability

Please report security problems privately, using GitHub's private vulnerability reporting: open this repository's Security tab and choose Report a vulnerability. Don't open a public issue for one.

Include what you found, how to reproduce it and which version or commit you saw it in. You will get a reply as soon as the owner can give one; this is a small project run by one person, so please be patient.

## What to know about the scanner

The scanner's remote protocol has no authentication. Anyone who can reach a scanner's network port can control it. Never expose a scanner, or anything that relays to one, to the internet. Keep it on a network you trust.

Reports about that property of the protocol itself aren't vulnerabilities in Noctule Scan, but suggestions for making the app safer around it are welcome as ordinary issues.

## Real radio traffic

If you attach logs, hit logs, recordings or screenshots to a report, remove real system names, frequencies, talkgroups and unit IDs first.
