FROM mcr.microsoft.com/dotnet/aspnet:6.0
WORKDIR /retype

# Instructs Retype to listen on all interfaces unless otherwise specified
# in the config file or --host argument during watch and run commands.
ENV RETYPE_DEFAULT_HOST="0.0.0.0"

ADD . /
