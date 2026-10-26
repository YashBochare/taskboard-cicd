# TaskBoard – Integrated CI/CD Pipeline (Experiment 4)

A Node.js web application delivered to AWS by a Jenkins CI/CD pipeline.

```
Developer ──git push──▶ GitHub ──webhook──▶ Jenkins (EC2) ──▶ Amazon ECR ──SSM──▶ App server (EC2) ──▶ Users
                                  checkout · npm ci · unit tests · docker build · smoke test · push · deploy · verify
```

| Path | Purpose |
|---|---|
| `app/` | TaskBoard application (Express), unit tests (`node:test`), `Dockerfile` |
| `Jenkinsfile` | Declarative pipeline: build → test → containerise → push → deploy → verify |
| `jenkins/` | Jenkins controller image with plugins and Configuration-as-Code (`casc.yaml`) |
| `infra/` | AWS CLI scripts that provision and tear down the infrastructure |

## Run locally

```bash
cd app && npm install && npm test && npm start   # http://localhost:3000
```

## Provision on AWS

```bash
REPO_URL=https://github.com/YashBochare/taskboard-cicd infra/provision.sh
```

Every push to `main` then triggers the `taskboard-cicd` Jenkins job, which deploys the new
version to the app server only if all tests and checks pass.
