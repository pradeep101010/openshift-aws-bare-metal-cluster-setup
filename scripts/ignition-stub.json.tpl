{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "http://${bastion_ip}:8080/ignition/${role}.ign"
        }
      ]
    }
  }
}