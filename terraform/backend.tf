# Ollama on EKS - Terraform S3 Backend + State Locking
# @author Shanaka Jayasundera - shanakaj@gmail.com
#
# Prerequisites:
#   1. Create S3 bucket:
#      aws s3api create-bucket \
#        --bucket ollama-eks-tfstate-183758910727 \
#        --region ap-southeast-2 \
#        --create-bucket-configuration LocationConstraint=ap-southeast-2
#      aws s3api put-bucket-versioning \
#        --bucket ollama-eks-tfstate-183758910727 \
#        --versioning-configuration Status=Enabled
#      aws s3api put-bucket-encryption \
#        --bucket ollama-eks-tfstate-183758910727 \
#        --server-side-encryption-configuration \
#          '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
#      aws s3api put-public-access-block \
#        --bucket ollama-eks-tfstate-183758910727 \
#        --public-access-block-configuration \
#          BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
#
#   2. Create DynamoDB table:
#      aws dynamodb create-table \
#        --table-name ollama-eks-tfstate-lock \
#        --attribute-definitions AttributeName=LockID,AttributeType=S \
#        --key-schema AttributeName=LockID,KeyType=HASH \
#        --billing-mode PAY_PER_REQUEST \
#        --region ap-southeast-2
#
#   3. Migrate state:
#      terraform init -migrate-state
#
#   4. Verify:
#      terraform plan  # Should show no changes

terraform {
  backend "s3" {
    bucket         = "ollama-eks-tfstate-183758910727"
    key            = "ollama-eks/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "ollama-eks-tfstate-lock"
  }
}
