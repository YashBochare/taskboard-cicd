// TaskBoard CI/CD pipeline.
// Triggered by a GitHub push webhook. Builds, tests and containerises the app,
// pushes the image to Amazon ECR and deploys it to the EC2 app server via AWS SSM.
//
// AWS_REGION, ECR_REGISTRY, APP_INSTANCE_ID and APP_PRIVATE_IP are set as global
// environment variables by Jenkins Configuration-as-Code (jenkins/casc.yaml).

pipeline {
  agent any

  options {
    timestamps()
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    IMAGE_NAME  = 'taskboard'
    APP_VERSION = "1.0.${env.BUILD_NUMBER}"
    IMAGE       = "${env.ECR_REGISTRY}/taskboard"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.GIT_MSG   = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
        }
        echo "Building commit ${env.GIT_SHORT}: ${env.GIT_MSG}"
      }
    }

    stage('Install Dependencies') {
      steps {
        dir('app') {
          sh 'node --version && npm --version'
          sh 'npm ci --no-audit --no-fund'
        }
      }
    }

    stage('Unit Tests') {
      steps {
        dir('app') {
          sh 'npm run test:ci'
        }
      }
      post {
        always {
          junit 'app/test-results.xml'
        }
      }
    }

    stage('Build Docker Image') {
      steps {
        sh """
          docker build \
            --build-arg APP_VERSION=${APP_VERSION} \
            -t ${IMAGE}:${BUILD_NUMBER} \
            -t ${IMAGE}:latest \
            app
        """
      }
    }

    stage('Container Smoke Test') {
      steps {
        sh """
          docker rm -f smoke-${BUILD_NUMBER} >/dev/null 2>&1 || true
          docker run -d --name smoke-${BUILD_NUMBER} ${IMAGE}:${BUILD_NUMBER}
          for i in \$(seq 1 15); do
            if docker exec smoke-${BUILD_NUMBER} wget -qO- http://127.0.0.1:3000/health; then
              echo; echo 'Smoke test passed'; exit 0
            fi
            sleep 2
          done
          echo 'Container did not become healthy'; docker logs smoke-${BUILD_NUMBER}; exit 1
        """
      }
      post {
        always {
          sh "docker rm -f smoke-${BUILD_NUMBER} >/dev/null 2>&1 || true"
        }
      }
    }

    stage('Push to Amazon ECR') {
      steps {
        sh """
          aws ecr get-login-password --region ${AWS_REGION} \
            | docker login --username AWS --password-stdin ${ECR_REGISTRY}
          docker push ${IMAGE}:${BUILD_NUMBER}
          docker push ${IMAGE}:latest
        """
      }
    }

    stage('Deploy to EC2') {
      steps {
        script {
          def deployedAt = new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone('UTC'))
          def commands = [
            "aws ecr get-login-password --region ${env.AWS_REGION} | docker login --username AWS --password-stdin ${env.ECR_REGISTRY}",
            "docker pull ${env.IMAGE}:${env.BUILD_NUMBER}",
            "docker rm -f taskboard || true",
            "docker run -d --name taskboard --restart unless-stopped -p 80:3000 -e BUILD_NUMBER=${env.BUILD_NUMBER} -e GIT_COMMIT=${env.GIT_COMMIT} -e DEPLOYED_AT=${deployedAt} ${env.IMAGE}:${env.BUILD_NUMBER}",
            "docker image prune -af --filter until=24h || true",
          ]
          writeFile file: 'ssm-params.json', text: groovy.json.JsonOutput.toJson([commands: commands])
          def commandId = sh(returnStdout: true, script: """
            aws ssm send-command --region ${env.AWS_REGION} \
              --instance-ids ${env.APP_INSTANCE_ID} \
              --document-name AWS-RunShellScript \
              --comment "Deploy taskboard build ${env.BUILD_NUMBER}" \
              --parameters file://ssm-params.json \
              --query Command.CommandId --output text
          """).trim()
          echo "SSM command ${commandId} sent to ${env.APP_INSTANCE_ID}"
          sh """
            aws ssm wait command-executed --region ${AWS_REGION} --command-id ${commandId} --instance-id ${APP_INSTANCE_ID} || true
            aws ssm get-command-invocation --region ${AWS_REGION} --command-id ${commandId} --instance-id ${APP_INSTANCE_ID} \
              --query '{Status:Status,Output:StandardOutputContent,Errors:StandardErrorContent}' --output json
            test "\$(aws ssm get-command-invocation --region ${AWS_REGION} --command-id ${commandId} --instance-id ${APP_INSTANCE_ID} --query Status --output text)" = Success
          """
        }
      }
    }

    stage('Verify Deployment') {
      steps {
        sh """
          for i in \$(seq 1 20); do
            BODY=\$(curl -fs http://${APP_PRIVATE_IP}/health || true)
            echo "\$BODY"
            if echo "\$BODY" | grep -q '"build":"${BUILD_NUMBER}"'; then
              echo 'Live application is serving build ${BUILD_NUMBER}'; exit 0
            fi
            sleep 3
          done
          echo 'Deployed application did not report the expected build'; exit 1
        """
      }
    }
  }

  post {
    success {
      echo "Deployed TaskBoard ${APP_VERSION} (commit ${env.GIT_SHORT}) to production."
    }
    failure {
      echo 'Pipeline failed - the previously deployed version keeps serving traffic.'
    }
    always {
      sh "docker image rm ${IMAGE}:${BUILD_NUMBER} >/dev/null 2>&1 || true"
    }
  }
}
