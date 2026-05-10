terraform {
  backend "s3" {
    bucket = "itba-tp-fraud-tfstate"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
