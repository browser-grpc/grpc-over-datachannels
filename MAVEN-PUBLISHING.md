# Publishing grpc-dc for Java (maintainers)

Two channels publish the same artifact
(`io.github.browser-grpc:grpc-dc`, same version):

## Maven Central (discovery channel)

`.github/workflows/publish-maven.yml` (manual dispatch)
uploads the signed bundle to Maven Central via the
Central Portal API. Sonatype counts deployments per
organization per month, so Central is synced in a
batched weekly slot, not on every release.

## GitHub-hosted Maven repo (every release)

`.github/workflows/publish-maven-github.yml` (manual
dispatch) commits a static Maven repository under
`docs/maven/`; GitHub Pages serves it at
`https://browser-grpc.github.io/grpc-over-datachannels/maven/`.
No deployment-count limit and no credentials, so this
channel ships with every release. Consumers add:

```xml
<repository>
  <id>github-pages</id>
  <url>https://browser-grpc.github.io/grpc-over-datachannels/maven/</url>
</repository>
```

and depend on `io.github.browser-grpc:grpc-dc` as usual.
Anonymous reads; Gradle uses
`maven { url 'https://browser-grpc.github.io/grpc-over-datachannels/maven/' }`.
