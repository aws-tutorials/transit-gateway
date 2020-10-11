## Start with transit gateway creation
export mytgwyid=`aws ec2 create-transit-gateway --description MyTGW \
        --options=AmazonSideAsn=64516,AutoAcceptSharedAttachments=enable,DefaultRouteTableAssociation=enable,DefaultRouteTablePropagation=enable,VpnEcmpSupport=enable,DnsSupport=enable \
        | jq -r .TransitGateway.TransitGatewayId `
echo "Transit gateway id = $mytgwyid"

## Create VPC
export extvpc=`aws ec2 create-vpc \
    --cidr-block 10.1.0.0/16 \
    --tag-specifications="ResourceType=vpc,Tags=[{Key=Name,Value=ext-vpc}]" \
    --region=us-east-1 | jq -r .Vpc.VpcId`
echo "Ext VPC = $extvpc"

export intvpc=`aws ec2 create-vpc \
    --cidr-block 10.2.0.0/16 \
    --tag-specifications="ResourceType=vpc,Tags=[{Key=Name,Value=int-vpc}]" \
    --region=us-east-1 | jq -r .Vpc.VpcId`
echo "Int VPC = $intvpc"

## Create Subnet #########################################################
export extsubnet=`aws ec2 create-subnet \
    --vpc-id $extvpc \
    --tag-specifications="ResourceType=subnet,Tags=[{Key=Name,Value=ext-subnet}]" \
    --cidr-block 10.1.0.0/24 \
    --region=us-east-1 | jq -r .Subnet.SubnetId`
echo "extsubnet = $extsubnet"

export intsubnet=`aws ec2 create-subnet \
    --vpc-id $intvpc \
    --tag-specifications="ResourceType=subnet,Tags=[{Key=Name,Value=int-subnet}]" \
    --cidr-block 10.2.0.0/24 \
    --region=us-east-1 | jq -r .Subnet.SubnetId`
echo "intsubnet = $intsubnet"

## Create Internet gateway

export extigw=`aws ec2 create-internet-gateway \
   --tag-specifications="ResourceType=internet-gateway,Tags=[{Key=Name,Value=ext-igw}]"  \
   | jq -r .InternetGateway.InternetGatewayId`

echo "external Interet gateway id = $extigw"

# Attach to Vpc
aws ec2 attach-internet-gateway \
    --internet-gateway-id $extigw \
    --vpc-id $extvpc
echo "Ext Interet gateway attached"


## Create SG #########################################################
export extsg=`aws ec2 create-security-group \
    --group-name ExtSecurityGroup \
    --description "Ext security group" \
    --vpc-id $extvpc \
    --region=us-east-1 | jq -r .GroupId`
echo "extsg = $extsg"

export intsg=`aws ec2 create-security-group \
    --group-name IntSecurityGroup \
    --description "Int security group" \
    --vpc-id $intvpc \
    --region=us-east-1 | jq -r .GroupId`
echo "intsg = $intsg"

## Create SG Rules #########################################################

aws ec2 authorize-security-group-ingress \
    --group-id $extsg \
    --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=0.0.0.0/0,Description="SSH access from anywhere"}]' \
    --region=us-east-1

aws ec2 authorize-security-group-ingress \
    --group-id $extsg \
    --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges='[{CidrIp=0.0.0.0/0,Description="HTTP access from anywhere"}]' \
    --region=us-east-1

aws ec2 authorize-security-group-ingress \
    --group-id $intsg \
    --ip-permissions IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges='[{CidrIp=10.1.0.0/16,Description="SSH access from ext vpc only"}]' \
    --region=us-east-1

echo "Security group updated with rules"

## Create Key Pair and user data  #################################
export myami=`aws ec2 describe-images --query 'sort_by(Images, &CreationDate)[*].[CreationDate,Name,ImageId]' --filters "Name=name,Values=RHEL-8*" --region us-east-1 | jq -r .[0][2]`
echo " ami = $myami"
rm -rf internalkey.pem
aws ec2 create-key-pair --key-name internalkey | jq -r .KeyMaterial > internalkey.pem
chmod 400 internalkey.pem
echo "Keypair created and saved"

cat > userdata.txt<<EOL
#!/bin/bash
sudo yum update -y
sudo yum install httpd -y
echo " Apache Server " > /var/www/html/index.html
export myip=\`curl http://169.254.169.254/latest/meta-data/local-ipv4/\`
echo " My Ip is \$myip " >> /var/www/html/index.html
sudo service httpd start
EOL
echo "Userdata created and saved"

## Create ec2s #################################

extec2id=`aws ec2 run-instances \
    --image-id $myami \
    --subnet-id $extsubnet \
    --security-group-ids $extsg \
    --associate-public-ip-address \
    --user-data file://userdata.txt \
    --instance-type t2.medium \
    --tag-specifications="ResourceType=instance,Tags=[{Key=Name,Value=ec2-extvpc}]" \
    --key-name internalkey | jq -r .Instances[0].InstanceId`

intec2id=`aws ec2 run-instances \
    --image-id $myami \
    --subnet-id $intsubnet \
    --security-group-ids $intsg \
    --tag-specifications="ResourceType=instance,Tags=[{Key=Name,Value=ec2-intvpc}]" \
    --instance-type t2.medium \
    --key-name internalkey | jq -r .Instances[0].InstanceId`

sleep 10
export publicip=`aws ec2 describe-instances --instance-ids $extec2id| jq -r .Reservations[0].Instances[0].PublicIpAddress`
export privateip=`aws ec2 describe-instances --instance-ids $intec2id| jq -r .Reservations[0].Instances[0].PrivateIpAddress`
echo "External ec2 IP $publicip "
echo "Internal ec2 IP $privateip "

export tgwstate=`aws ec2 describe-transit-gateways --transit-gateway-ids $mytgwyid | jq -r .TransitGateways[0].State`
echo "Transit gateway state is $tgwstate"
while [ "$tgwstate" == "pending" ]
do
   sleep 20
   tgwstate=`aws ec2 describe-transit-gateways --transit-gateway-ids $mytgwyid | jq -r .TransitGateways[0].State`
   echo "Transit gateway state is $tgwstate"
done

## Create Transit gateway attachments
export exttgwyattach=`aws ec2  create-transit-gateway-vpc-attachment \
    --transit-gateway-id $mytgwyid \
    --vpc-id $extvpc \
    --subnet-ids $extsubnet  \
    --tag-specifications="ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=extvpc-tw-attach}]" \
    --region=us-east-1 | jq -r .TransitGatewayVpcAttachment.TransitGatewayAttachmentId `
echo "ext vpc tgwy attachmentid = $exttgwyattach"

export inttgwyattach=`aws ec2  create-transit-gateway-vpc-attachment \
    --transit-gateway-id $mytgwyid \
    --vpc-id $intvpc \
    --subnet-ids $intsubnet  \
    --tag-specifications="ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=intvpc-tw-attach}]" \
    --region=us-east-1 | jq -r .TransitGatewayVpcAttachment.TransitGatewayAttachmentId `
echo "int vpc tgwy attachmentid = $inttgwyattach"

## Get Routing table and add internet gateway
export extroutetable=`aws ec2 describe-route-tables \
    --filters Name=vpc-id,Values=$extvpc \
   | jq -r .RouteTables[0].RouteTableId `

aws ec2 create-route --route-table-id $extroutetable  \
     --destination-cidr-block 0.0.0.0/0 \
     --gateway-id $extigw

export introutetable=`aws ec2 describe-route-tables \
    --filters Name=vpc-id,Values=$intvpc \
   | jq -r .RouteTables[0].RouteTableId `

## Give some time gateway attachments and add route in subnet routing table to reach VPC
sleep 30
aws ec2 create-route --route-table-id $extroutetable \
      --destination-cidr-block 10.2.0.0/16 \
      --transit-gateway-id "$mytgwyid"
aws ec2 create-route --route-table-id $introutetable \
      --destination-cidr-block 10.1.0.0/16 \
      --transit-gateway-id $mytgwyid
echo " Route Tables updated to use transit hub for other VPC's"

## Wait and try to get in EC2 in internal subnet using external EC2.
sleep 80
ssh -t -i internalkey.pem -oStrictHostKeyChecking=no ec2-user@$publicip ssh $privateip
