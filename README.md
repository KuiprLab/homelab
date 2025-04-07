<h1 align="center">
  <br><img src="project-logo.svg" height="192px">
</h1>

# My Home Ifrastructure Using Flux
![Validate and Protect Flux Resources](https://github.com/KuiprLab/homelab/actions/workflows/validate.yaml/badge.svg)
![GitHub License](https://img.shields.io/github/license/KuiprLab/homelab)

This repository contains the configuration for my personal homelab Kubernetes cluster. This homelab setup provides a powerful learning environment and a platform to host personal applications and services.

## Stack Overview

My homelab Kubernetes infrastructure is built using the following technologies:

### Proxmox VE
Proxmox serves as the hypervisor layer, allowing me to run multiple virtual machines on my physical hardware. This provides flexibility and efficient resource utilization for my homelab environment.

### Talos Linux
Talos Linux is a specialized, minimal OS designed specifically for running Kubernetes. Its immutable design and security-focused approach make it an excellent choice for a homelab cluster where I want to minimize maintenance overhead.

### FluxCD
Flux enables GitOps-based management of my cluster, allowing me to declare my desired state in Git and have it automatically applied to the cluster. This makes configuration tracking, changes, and rollbacks simple and reliable.

### Longhorn
Longhorn provides distributed block storage for the cluster, enabling persistent storage for stateful applications. Its integration with Kubernetes makes it easy to provide reliable storage for my homelab services.

## Purpose

This homelab setup allows me to:
- Learn and experiment with Kubernetes and cloud-native technologies
- Host personal services and applications
- Test configurations before potentially implementing them in production environments
- Develop skills in modern infrastructure management

## Getting Started

Additional documentation about setup, configuration, and management can be found in the respective directories for each component.

Feel free to explore this repository to understand how these technologies are integrated in a homelab environment.
