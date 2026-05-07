terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}

# Backend remoto (stub para futuras iteraciones fuera del laboratorio).
# El laboratorio de AWS Academy es efímero, por lo que se usa estado local.
# Cuando exista una cuenta estable, migrar a S3 + DynamoDB:
#
# terraform {
#   backend "s3" {
#     bucket         = "itba-tp-fraud-tfstate"
#     key            = "fraud-engine/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "itba-tp-fraud-tflock"
#     encrypt        = true
#   }
# }
