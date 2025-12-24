#########################################################
#    Keypairs to access EC2 instances (first option)    #
#########################################################
# Set up the AWS KeyPair 
# USAGE: This resource will be used in EC2 instances
resource "aws_key_pair" "tls_key_k8s_node" {
    key_name    = local.keypair_name 
    public_key  = tls_private_key.tls_key_k8s_node.public_key_openssh
}
# Generate a TLS Private Key (Stored Locally)
resource "tls_private_key" "tls_key_k8s_node" {
    algorithm   = "RSA"
    rsa_bits    = 4096
}
# Output the private key to a local file for future use
resource "local_file" "private_key" {
    content         = tls_private_key.tls_key_k8s_node.private_key_pem
    filename        = "${path.module}/${local.keypair_name}.pem"  # Path to store the private key
    file_permission = "0400"
}
