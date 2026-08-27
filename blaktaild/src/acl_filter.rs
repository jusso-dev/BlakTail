use crate::Peer;
use std::net::IpAddr;

pub const ACL_CHAIN: &str = "BLAKTAIL-ACL";

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FilterPlan {
    pub enforce: bool,
    pub ipv4: Vec<Vec<String>>,
    pub ipv6: Vec<Vec<String>>,
}

pub fn overlay_host_addrs(allowed_ips: &[String]) -> Vec<String> {
    allowed_ips
        .iter()
        .filter_map(|route| {
            let (address, prefix) = route.split_once('/')?;
            let parsed: IpAddr = address.parse().ok()?;
            let prefix: u8 = prefix.parse().ok()?;
            match parsed {
                IpAddr::V4(_) if prefix == 32 => Some(parsed.to_string()),
                IpAddr::V6(_) if prefix == 128 => Some(parsed.to_string()),
                _ => None,
            }
        })
        .collect()
}

pub fn iptables_port(spec: &str) -> Option<String> {
    let spec = spec.trim();
    if spec == "*" {
        return Some("1:65535".into());
    }
    if let Some((start, end)) = spec.split_once('-') {
        let start: u16 = start.parse().ok()?;
        let end: u16 = end.parse().ok()?;
        if start == 0 || end == 0 || start > end {
            return None;
        }
        return Some(if start == end {
            start.to_string()
        } else {
            format!("{start}:{end}")
        });
    }
    let port: u16 = spec.parse().ok()?;
    (port != 0).then(|| port.to_string())
}

pub fn plan_overlay_filter(peers: &[Peer]) -> FilterPlan {
    if !peers.iter().any(|peer| peer.ingress.is_some()) {
        return FilterPlan::default();
    }
    let mut ipv4 = vec![established()];
    let mut ipv6 = vec![established()];
    for peer in peers {
        let ingress = peer.ingress.clone().unwrap_or_else(|| crate::PeerIngress {
            all: true,
            ..crate::PeerIngress::default()
        });
        for address in overlay_host_addrs(&peer.allowed_ips) {
            let rules = if address.contains(':') {
                &mut ipv6
            } else {
                &mut ipv4
            };
            append_peer_rules(rules, &address, &ingress);
        }
    }
    ipv4.extend(final_reject(false));
    ipv6.extend(final_reject(true));
    FilterPlan {
        enforce: true,
        ipv4,
        ipv6,
    }
}

pub fn sshd_policy_config(peers: &[Peer]) -> String {
    let mut out = String::from("# managed by blaktaild\n");
    for peer in peers {
        let Some(ingress) = &peer.ingress else {
            continue;
        };
        if ingress.ssh_users.is_empty() || ingress.ssh_users.iter().any(|user| user == "*") {
            continue;
        }
        let addresses = overlay_host_addrs(&peer.allowed_ips);
        if addresses.is_empty() {
            continue;
        }
        out.push_str("Match Address ");
        out.push_str(&addresses.join(","));
        out.push_str("\n    AllowUsers ");
        out.push_str(&ingress.ssh_users.join(" "));
        out.push('\n');
    }
    out
}

fn established() -> Vec<String> {
    vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-m".into(),
        "conntrack".into(),
        "--ctstate".into(),
        "RELATED,ESTABLISHED".into(),
        "-j".into(),
        "ACCEPT".into(),
    ]
}

fn append_peer_rules(rules: &mut Vec<Vec<String>>, source: &str, ingress: &crate::PeerIngress) {
    for spec in &ingress.deny_tcp {
        if let Some(port) = iptables_port(spec) {
            rules.push(reject_port(source, "tcp", &port, true));
        }
    }
    for spec in &ingress.deny_udp {
        if let Some(port) = iptables_port(spec) {
            rules.push(reject_port(source, "udp", &port, false));
        }
    }
    if ingress.deny_icmp {
        rules.push(reject_icmp(source));
    }
    if ingress.all {
        rules.push(accept_source(source));
        return;
    }
    for spec in &ingress.tcp {
        if let Some(port) = iptables_port(spec) {
            rules.push(accept_port(source, "tcp", &port));
        }
    }
    for spec in &ingress.udp {
        if let Some(port) = iptables_port(spec) {
            rules.push(accept_port(source, "udp", &port));
        }
    }
    if ingress.icmp {
        rules.push(accept_icmp(source));
    }
}

fn accept_source(source: &str) -> Vec<String> {
    vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-s".into(),
        source.into(),
        "-j".into(),
        "ACCEPT".into(),
    ]
}

fn accept_port(source: &str, protocol: &str, port: &str) -> Vec<String> {
    vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-s".into(),
        source.into(),
        "-p".into(),
        protocol.into(),
        "--dport".into(),
        port.into(),
        "-j".into(),
        "ACCEPT".into(),
    ]
}

fn accept_icmp(source: &str) -> Vec<String> {
    let protocol = if source.contains(':') {
        "icmpv6"
    } else {
        "icmp"
    };
    vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-s".into(),
        source.into(),
        "-p".into(),
        protocol.into(),
        "-j".into(),
        "ACCEPT".into(),
    ]
}

fn reject_port(source: &str, protocol: &str, port: &str, tcp: bool) -> Vec<String> {
    let mut rule = vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-s".into(),
        source.into(),
        "-p".into(),
        protocol.into(),
        "--dport".into(),
        port.into(),
        "-j".into(),
        "REJECT".into(),
        "--reject-with".into(),
    ];
    rule.push(if tcp {
        "tcp-reset".into()
    } else if source.contains(':') {
        "icmp6-port-unreachable".into()
    } else {
        "icmp-port-unreachable".into()
    });
    rule
}

fn reject_icmp(source: &str) -> Vec<String> {
    let (protocol, reject) = if source.contains(':') {
        ("icmpv6", "icmp6-port-unreachable")
    } else {
        ("icmp", "icmp-port-unreachable")
    };
    vec![
        "-A".into(),
        ACL_CHAIN.into(),
        "-s".into(),
        source.into(),
        "-p".into(),
        protocol.into(),
        "-j".into(),
        "REJECT".into(),
        "--reject-with".into(),
        reject.into(),
    ]
}

fn final_reject(ipv6: bool) -> [Vec<String>; 2] {
    let icmp = if ipv6 {
        "icmp6-port-unreachable"
    } else {
        "icmp-port-unreachable"
    };
    [
        vec![
            "-A".into(),
            ACL_CHAIN.into(),
            "-p".into(),
            "tcp".into(),
            "-j".into(),
            "REJECT".into(),
            "--reject-with".into(),
            "tcp-reset".into(),
        ],
        vec![
            "-A".into(),
            ACL_CHAIN.into(),
            "-j".into(),
            "REJECT".into(),
            "--reject-with".into(),
            icmp.into(),
        ],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Peer, PeerIngress};
    use uuid::Uuid;

    fn peer(ingress: PeerIngress) -> Peer {
        Peer {
            id: Uuid::from_u128(2),
            name: "store".into(),
            wg_public_key: "key".into(),
            endpoint: None,
            allowed_ips: vec!["100.64.0.2/32".into(), "fd12:3456::2/128".into()],
            dns_name: "store.blaktail".into(),
            tags: vec![],
            relay_endpoint: None,
            ingress: Some(ingress),
        }
    }

    #[test]
    fn missing_ingress_leaves_legacy_peers_unfiltered() {
        let mut legacy = peer(PeerIngress::default());
        legacy.ingress = None;
        assert!(!plan_overlay_filter(&[legacy]).enforce);
    }

    #[test]
    fn restricted_tcp_and_ssh_compile_accept_and_reject_rules() {
        let plan = plan_overlay_filter(&[peer(PeerIngress {
            tcp: vec!["22".into(), "8080".into()],
            deny_tcp: vec!["8081".into()],
            ssh_users: vec!["blaktail".into()],
            ..PeerIngress::default()
        })]);
        assert!(plan.enforce);
        let joined: Vec<String> = plan.ipv4.iter().map(|rule| rule.join(" ")).collect();
        assert!(joined
            .iter()
            .any(|rule| rule.contains("-s 100.64.0.2 -p tcp --dport 8080 -j ACCEPT")));
        assert!(joined
            .iter()
            .any(|rule| rule.contains("-s 100.64.0.2 -p tcp --dport 8081 -j REJECT")));
        assert!(joined
            .iter()
            .any(|rule| rule.ends_with("-p tcp -j REJECT --reject-with tcp-reset")));
        let v6: Vec<String> = plan.ipv6.iter().map(|rule| rule.join(" ")).collect();
        assert!(v6
            .iter()
            .any(|rule| rule.contains("-s fd12:3456::2 -p tcp --dport 22 -j ACCEPT")));
    }

    #[test]
    fn sshd_match_blocks_list_allowed_users_per_source() {
        let config = sshd_policy_config(&[peer(PeerIngress {
            ssh_users: vec!["blaktail".into()],
            ..PeerIngress::default()
        })]);
        assert!(config.contains("Match Address 100.64.0.2,fd12:3456::2"));
        assert!(config.contains("AllowUsers blaktail"));
    }
}
