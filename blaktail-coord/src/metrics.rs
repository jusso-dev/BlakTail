use std::{
    fmt::Write as _,
    sync::atomic::{AtomicU64, Ordering::Relaxed},
    time::Duration,
};

const LATENCY_BUCKETS: &[(u64, &str)] = &[
    (5_000, "0.005"),
    (10_000, "0.01"),
    (25_000, "0.025"),
    (50_000, "0.05"),
    (100_000, "0.1"),
    (250_000, "0.25"),
    (500_000, "0.5"),
    (1_000_000, "1"),
    (2_500_000, "2.5"),
    (5_000_000, "5"),
];

#[derive(Clone, Copy)]
pub(crate) enum Operation {
    Register,
    Peers,
    Updates,
    Revoke,
}

impl Operation {
    fn label(self) -> &'static str {
        match self {
            Self::Register => "register",
            Self::Peers => "peers",
            Self::Updates => "updates",
            Self::Revoke => "revoke",
        }
    }
}

#[derive(Default)]
struct OperationMetrics {
    success: AtomicU64,
    error: AtomicU64,
    duration_count: AtomicU64,
    duration_micros: AtomicU64,
    duration_buckets: [AtomicU64; 10],
}

impl OperationMetrics {
    fn record(&self, status: u16, elapsed: Duration) {
        if status < 400 {
            self.success.fetch_add(1, Relaxed);
        } else {
            self.error.fetch_add(1, Relaxed);
        }
        let micros = elapsed.as_micros().min(u64::MAX as u128) as u64;
        self.duration_count.fetch_add(1, Relaxed);
        self.duration_micros.fetch_add(micros, Relaxed);
        for (index, (upper_bound, _)) in LATENCY_BUCKETS.iter().enumerate() {
            if micros <= *upper_bound {
                self.duration_buckets[index].fetch_add(1, Relaxed);
            }
        }
    }

    fn render(&self, output: &mut String, operation: Operation) {
        let label = operation.label();
        writeln!(
            output,
            "blaktail_coord_requests_total{{operation=\"{label}\",result=\"success\"}} {}",
            self.success.load(Relaxed)
        )
        .expect("writing to a String cannot fail");
        writeln!(
            output,
            "blaktail_coord_requests_total{{operation=\"{label}\",result=\"error\"}} {}",
            self.error.load(Relaxed)
        )
        .expect("writing to a String cannot fail");
        for (index, (_, upper_bound)) in LATENCY_BUCKETS.iter().enumerate() {
            writeln!(
                output,
                "blaktail_coord_request_duration_seconds_bucket{{operation=\"{label}\",le=\"{upper_bound}\"}} {}",
                self.duration_buckets[index].load(Relaxed)
            )
            .expect("writing to a String cannot fail");
        }
        let count = self.duration_count.load(Relaxed);
        writeln!(
            output,
            "blaktail_coord_request_duration_seconds_bucket{{operation=\"{label}\",le=\"+Inf\"}} {count}"
        )
        .expect("writing to a String cannot fail");
        writeln!(
            output,
            "blaktail_coord_request_duration_seconds_sum{{operation=\"{label}\"}} {:.6}",
            self.duration_micros.load(Relaxed) as f64 / 1_000_000.0
        )
        .expect("writing to a String cannot fail");
        writeln!(
            output,
            "blaktail_coord_request_duration_seconds_count{{operation=\"{label}\"}} {count}"
        )
        .expect("writing to a String cannot fail");
    }
}

#[derive(Default)]
pub struct CoordMetrics {
    register: OperationMetrics,
    peers: OperationMetrics,
    updates: OperationMetrics,
    revoke: OperationMetrics,
}

impl CoordMetrics {
    pub(crate) fn record(&self, operation: Operation, status: u16, elapsed: Duration) {
        match operation {
            Operation::Register => &self.register,
            Operation::Peers => &self.peers,
            Operation::Updates => &self.updates,
            Operation::Revoke => &self.revoke,
        }
        .record(status, elapsed);
    }

    pub fn render(&self, active_nodes: u64) -> String {
        let mut output = String::from(
            "# HELP blaktail_coord_requests_total Coordinator API requests by operation and result.\n\
             # TYPE blaktail_coord_requests_total counter\n\
             # HELP blaktail_coord_request_duration_seconds Coordinator API request latency.\n\
             # TYPE blaktail_coord_request_duration_seconds histogram\n",
        );
        self.register.render(&mut output, Operation::Register);
        self.peers.render(&mut output, Operation::Peers);
        self.updates.render(&mut output, Operation::Updates);
        self.revoke.render(&mut output, Operation::Revoke);
        output.push_str(
            "# HELP blaktail_coord_active_nodes Currently authorised, unexpired nodes.\n\
             # TYPE blaktail_coord_active_nodes gauge\n",
        );
        writeln!(output, "blaktail_coord_active_nodes {active_nodes}")
            .expect("writing to a String cannot fail");
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_cumulative_histogram_and_result_counters() {
        let metrics = CoordMetrics::default();
        metrics.record(Operation::Peers, 200, Duration::from_millis(7));
        metrics.record(Operation::Peers, 401, Duration::from_millis(30));
        let rendered = metrics.render(3);
        assert!(rendered
            .contains("blaktail_coord_requests_total{operation=\"peers\",result=\"success\"} 1"));
        assert!(rendered
            .contains("blaktail_coord_requests_total{operation=\"peers\",result=\"error\"} 1"));
        assert!(rendered.contains(
            "blaktail_coord_request_duration_seconds_bucket{operation=\"peers\",le=\"0.01\"} 1"
        ));
        assert!(rendered.contains(
            "blaktail_coord_request_duration_seconds_bucket{operation=\"peers\",le=\"0.05\"} 2"
        ));
        assert!(rendered.contains("blaktail_coord_active_nodes 3"));
    }
}
