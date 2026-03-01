output "resource_presets" {
    description = "The list of s3 objects set up for the cluster_app"
    value       = {
        tny = {
            cpu = "25m"
            mem = "64Mi"
        }
        sml = {
            cpu = "50m"
            mem = "128Mi"
        }
        med = {
            cpu = "100m"
            mem = "256Mi"
        }
        lrg = {
            cpu = "200m"
            mem = "256Mi"
        }
        xl = {
            cpu = "275m"
            mem = "384Mi"
        }
        xxl = {
            cpu = "500m"
            mem = "512Mi"
        }
    }
}