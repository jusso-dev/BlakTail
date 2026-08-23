use std::{collections::HashMap, io, net::SocketAddr};
use tokio::net::UdpSocket;

pub const REGISTER: u8 = 1;
pub const SEND: u8 = 2;
pub const FORWARDED: u8 = 3;
pub const HEADER: usize = 17;

pub fn is_australian_region(region: &str) -> bool {
    matches!(
        region.trim().to_ascii_lowercase().as_str(),
        "ap-southeast-2"
            | "australiaeast"
            | "australiasoutheast"
            | "australia-southeast1"
            | "australia-southeast2"
    )
}

/// Relays opaque (normally WireGuard-encrypted) UDP payloads. Clients first send
/// REGISTER + their 16-byte node id, then SEND + destination id + payload.
pub async fn serve(socket: UdpSocket) -> io::Result<()> {
    let mut clients: HashMap<[u8; 16], SocketAddr> = HashMap::new();
    let mut buf = vec![0u8; 65_535];
    loop {
        let (len, source_addr) = socket.recv_from(&mut buf).await?;
        if len < HEADER {
            continue;
        }
        let mut id = [0u8; 16];
        id.copy_from_slice(&buf[1..HEADER]);
        match buf[0] {
            REGISTER => {
                clients.insert(id, source_addr);
            }
            SEND => {
                let Some(source_id) = clients
                    .iter()
                    .find_map(|(id, addr)| (*addr == source_addr).then_some(*id))
                else {
                    continue;
                };
                let Some(destination) = clients.get(&id).copied() else {
                    continue;
                };
                let mut packet = Vec::with_capacity(len);
                packet.push(FORWARDED);
                packet.extend_from_slice(&source_id);
                packet.extend_from_slice(&buf[HEADER..len]);
                socket.send_to(&packet, destination).await?;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{timeout, Duration};

    #[test]
    fn only_known_au_regions_are_accepted() {
        for region in ["ap-southeast-2", "australiaeast", "australia-southeast1"] {
            assert!(is_australian_region(region));
        }
        for region in ["", "us-east-1", "ap-southeast-1", "europe-west1"] {
            assert!(!is_australian_region(region));
        }
    }

    #[tokio::test]
    async fn forced_relay_ping_round_trip() {
        let relay = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let relay_addr = relay.local_addr().unwrap();
        let task = tokio::spawn(serve(relay));
        let a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let aid = [0xAA; 16];
        let bid = [0xBB; 16];
        for (socket, id) in [(&a, aid), (&b, bid)] {
            let mut p = vec![REGISTER];
            p.extend(id);
            socket.send_to(&p, relay_addr).await.unwrap();
        }
        tokio::task::yield_now().await;
        let mut ping = vec![SEND];
        ping.extend(bid);
        ping.extend(b"ping");
        a.send_to(&ping, relay_addr).await.unwrap();
        let mut buf = [0u8; 64];
        let (n, _) = timeout(Duration::from_secs(1), b.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..n], [&[FORWARDED][..], &aid, &b"ping"[..]].concat());
        let mut pong = vec![SEND];
        pong.extend(aid);
        pong.extend(b"pong");
        b.send_to(&pong, relay_addr).await.unwrap();
        let (n, _) = timeout(Duration::from_secs(1), a.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..n], [&[FORWARDED][..], &bid, &b"pong"[..]].concat());
        task.abort();
    }
}
