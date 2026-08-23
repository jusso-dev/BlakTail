output "console_url" {
  description = "Console base URL (HTTP until an ACM cert is configured)."
  value       = local.better_auth_url
}

output "coord_endpoint" {
  description = "Coordinator endpoint for agents and the console COORD_BASE_URL."
  value       = "https://${aws_lb.coord.dns_name}"
}

output "relay_endpoint" {
  description = "Relay UDP endpoint advertised to peers."
  value       = "${aws_lb.relay.dns_name}:3478"
}

output "ecr_repos" {
  description = "ECR repositories to push images to."
  value = {
    coord   = aws_ecr_repository.coord.repository_url
    relay   = aws_ecr_repository.relay.repository_url
    console = aws_ecr_repository.console.repository_url
  }
}
