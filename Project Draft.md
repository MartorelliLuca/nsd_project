# Project #3

Progetto di laboratorio di networking e sicurezza che integra routing tra siti, VPN OpenVPN in topologia hub-and-spoke, autenticazione 802.1X con assegnazione dinamica delle VLAN e controllo Mandatory Access Control con AppArmor.

## Obiettivo

Il progetto realizza una rete multi-sito in cui:

- **AS100** agisce come provider per tre siti del cliente e richiede la configurazione di peering iBGP tra i border router e di OSPF all'interno del dominio.
- **OpenVPN** collega i siti del cliente con una topologia hub-and-spoke in cui CE3 è il server, mentre CE1 e CE2 sono client.
- **VPN Site 1** ospita un client sensibile che deve essere protetto tramite Mandatory Access Control usando AppArmor.
- **VPN Site 2** ospita una LAN autenticata via 802.1X con VLAN assegnate dinamicamente da un server RADIUS remoto nel Site 3.
- **VPN Site 3** contiene CE2 e il server RADIUS che gestisce le richieste di accesso dei supplicant B1 e B2.

## Topologia

La topologia è composta da tre sedi cliente collegate attraverso il provider AS100:

- **Site 1**: CE1 e host client-A1.
- **Site 2**: CE3, uno switch autenticatore e due host `client-B1` e `client-B2`.
- **Site 3**: CE2 e server RADIUS.
- **Core provider**: tre router del provider in AS100 con connettività interna tramite OSPF e peering iBGP verso i customer edge.

## Requisiti funzionali

### 1. Routing del provider

Configurare il dominio **AS100** come infrastruttura di trasporto per i tre siti del cliente.

- Configurare **iBGP** tra i border router.
- Configurare **OSPF** nel core del provider.

### 2. Overlay VPN

Configurare **OpenVPN** in modalità hub-and-spoke con:

- **Server OpenVPN** su CE3.
- **Client OpenVPN** su CE1 e CE2.

L'obiettivo è consentire la connettività tra i siti del cliente sopra la rete del provider.

### 3. Sicurezza su VPN Site 1

Nel Site 1 il nodo `client-A1` è considerato sensibile e deve usare **Mandatory Access Control** con **AppArmor**.

Requisiti richiesti:

- AppArmor deve essere installato e attivo, ad esempio con `aa-status`.
- Deve essere creato e abilitato in modalità **enforce** un profilo AppArmor personalizzato per almeno un programma non banale presente su `client-A1`.
- Il profilo scelto deve implementare almeno una policy esplicita tra le seguenti:
  - negare la lettura delle credenziali del sistema operativo, ad esempio `/etc/shadow`;
  - negare l'accesso a chiavi private SSH o materiale sensibile dell'utente;
  - negare l'esecuzione di file con bassa integrità;
  - negare l'esecuzione da percorsi scrivibili globalmente come `/tmp`;
  - limitare la connettività di rete al traffico strettamente necessario.
- Il report deve includere il file del profilo AppArmor e i comandi usati per caricarlo o ricaricarlo, ad esempio `aa-enforce` o `apparmor_parser -r`.
- Il report deve mostrare due test riproducibili: un'azione consentita che ha successo e un'azione vietata che viene bloccata, con relativa evidenza nei log AppArmor, ad esempio tramite `journalctl | grep apparmor` o syslog.

### 4. Accesso autenticato su VPN Site 2

Nel Site 2, CE3 collega una LAN al dominio VPN e lo switch agisce da **authenticator** 802.1X per i client `B1` e `B2`, comunicando con il server RADIUS nel Site 3.

Requisiti richiesti:

- Configurare **802.1X** sul nodo autenticatore usando `hostapd`.
- Configurare i supplicant con `wpa_supplicant`.
- Sviluppare nello switch un programma **XDP** e un relativo programma **userspace** che analizzi i messaggi RADIUS 802.1X per estrarre le informazioni di autorizzazione.
- Dai messaggi di autorizzazione RADIUS devono essere lette le informazioni di autenticazione riuscita e il **MAC address** del client.
- In base all'esito dell'autenticazione, il bridge Linux deve concedere o negare l'accesso in funzione del MAC address.
- Il server RADIUS deve imporre l'assegnazione VLAN alle stazioni con i seguenti valori:
  - `client-B1` → VLAN ID **32**;
  - `client-B2` → VLAN ID **95**.
- Il programma XDP deve anche analizzare i messaggi RADIUS in ingresso per estrarre la VLAN assegnata.
- L'applicazione userspace deve mantenere una mappa e associare la VLAN ai client quando riceve i pacchetti di autenticazione con esito positivo.
- È accettato l'uso di qualunque linguaggio per il componente userspace.
- Il componente userspace può cooperare con eventi `hostapd` oppure gestire interamente gli eventi tramite una logica custom.
- Non è richiesta una gestione completa di tutti gli eventi del protocollo: è sufficiente implementare quelli necessari per le funzionalità descritte.

## Deliverable suggeriti

Una struttura ordinata del repository può essere la seguente:

```text
.
├── README.md
├── docs/
│   ├── report.md
│   ├── topology.png
│   └── test-cases.md
├── openvpn/
│   ├── server/
│   ├── ce1/
│   └── ce2/
├── routing/
│   ├── bgp/
│   └── ospf/
├── apparmor/
│   ├── profiles/
│   └── tests/
├── radius/
│   ├── freeradius/
│   └── clients/
├── dot1x/
│   ├── hostapd/
│   └── wpa_supplicant/
└── xdp/
    ├── kernel/
    └── userspace/
```

## Verifiche consigliate

Per documentare il progetto in modo chiaro, conviene includere almeno queste verifiche:

- Stato dei peer iBGP e delle adiacenze OSPF.
- Tunnel OpenVPN attivi tra CE3, CE1 e CE2.
- Stato di AppArmor e caricamento del profilo in modalità enforce.
- Test consentito e test bloccato con evidenza nei log AppArmor.
- Autenticazione riuscita di `client-B1` e `client-B2` via 802.1X.
- Assegnazione VLAN corretta: 32 per `client-B1`, 95 per `client-B2`.
- Tracciamento della decisione nel programma XDP/userspace e applicazione delle regole sul bridge Linux.

## Tecnologie coinvolte

- Routing dinamico con **iBGP** e **OSPF**.
- Tunneling **OpenVPN**.
- **AppArmor** per MAC e hardening dell'host sensibile.
- **FreeRADIUS**, **hostapd** e **wpa_supplicant** per AAA e 802.1X.
- **XDP/eBPF** e componente userspace per enforcement e VLAN assignment dinamico.
