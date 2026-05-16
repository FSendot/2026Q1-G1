terraform {
  # Partial backend config — bucket is derived at init time from the AWS account ID.
  # Run: make init
  backend "s3" {
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
