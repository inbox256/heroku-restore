#
# Restore db from another
#
if $0 == __FILE__

require 'net/http'
require 'open3'
require 'yaml'

require 'aws-sdk-resources'

FROM_NAME = 'rb-prod'

TO_NAME = 'rb-dev'

# FOR S3 bucket sync
FROM_S3 = 'rb-web'
TO_S3 = 'rb-dev'

# shell
def shell_cmd(cmd, desc)
  header([desc,cmd])

  stdin, stdout, stderr = Open3.popen3(cmd)
  (stdout.readlines + stderr.readlines).each { |line|
    yield line unless line.strip.size.zero?
  }
end

# s3 connection v2 style
#
def s3_connection()

  client = Aws::S3::Client.new(
      :access_key_id => ENV['AWS_ACCESS_KEY_ID'],
      :secret_access_key => ENV['AWS_SECRET_ACCESS_KEY'],
      :region => 'us-west-1')

  resource = Aws::S3::Resource.new(client: client)

  resource
end

def s3_bucket(bucketName)
  resource = s3_connection()
  resource.bucket(bucketName)
end

# Write to s3
#
def s3_upload(bucketName, filename)

  puts "#{__method__} b:#{bucketName} f:#{filename}"
  s3object = s3_bucket(bucketName).object(filename)

  url = URI.parse(s3object.presigned_url(:put, acl: 'public-read'))

  puts "#{__method__} url is #{url}"

  body = File.read(filename)

  Net::HTTP.start(url.host) do |http|
    http.send_request("PUT", url.request_uri, body, {
  # This is required, or Net::HTTP will add a default unsigned content-type.
      "content-type" => "",
    })
  end
  puts "#{__method__} complete. s3_location: #{url.to_s.split("?")[0]}"

  url.to_s.split("?")[0]
end

# Write to s3 with options
#
def s3_delete(bucketName, filename)
  puts "#{__method__} b:#{bucketName} f:#{filename}"
  s3_bucket(bucketName).object(filename).delete
end

# Pretty stdout for each step
#
def header(lines)
  delim = "#"
  puts "\n"
  puts delim + ("-" * 79)
  lines.each {|l| chunk(l, 78).each {|c| puts "#{delim} #{c}"}}
  puts delim + ("-" * 79)
  puts "\n"
end

# Break up string for header util
#
def chunk(string, size)
  string.scan(/.{1,#{size}}/)
end

raise "BAD BAD BAD don't overwrite production db" if TO_NAME.index('prod')

header(["moving data from #{FROM_NAME} to #{TO_NAME}"])

cmd = "heroku pg:backups capture --app #{FROM_NAME}"
shell_cmd(cmd, "create snapshot of #{FROM_NAME}") do |line|
  puts line
end

location = nil
cmd = "heroku pg:backups public-url --app #{FROM_NAME}"
shell_cmd(cmd, "get remote snapshot location") do |line|
  puts line
  location = line if line.index("s3.amazonaws.com")
end

raise "location of snapshot not found" if location.nil?

# copy it locally
t = Time.now.strftime("%Y%m%d%H%M")
filename = "#{t}_#{FROM_NAME}.dump"

cmd = defined?(JRUBY_VERSION) ? "curl -o #{filename} #{location}"
 : "curl -o #{filename} `heroku pg:backups public-url --app #{FROM_NAME}`"

shell_cmd(cmd, "copy it locally") do |line|
  puts line
end

# get S3 env
env_file = File.join(File.dirname(__FILE__), 'config', 'local_env.yml')
YAML.load(File.open(env_file)).each do |key, value|
  ENV[key.to_s] = value
end if File.exists?(env_file)

# upload to s3
header(["upload to s3"])
s3_location = s3_upload("#{FROM_NAME}-backups", filename)

# restore
cmd = "heroku pg:backups restore '#{s3_location}' HEROKU_POSTGRESQL_CYAN_URL --app #{TO_NAME} --confirm #{TO_NAME}"
shell_cmd(cmd, "restore #{TO_NAME}") do |line|
  puts line
end


header(["cleanup files"])
File.delete(filename)
s3_delete("#{FROM_NAME}-backups", filename)

cmd = "aws s3 sync s3://#{FROM_S3} s3://#{TO_S3} --acl public-read"
shell_cmd(cmd, "sync S3 buckets") do |line|
  puts line
end

header(["#{__FILE__} complete!"])

end