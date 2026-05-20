{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "http://${bastion_ip}/ignition/${role}.ign"
        }
      ]
    }
  }
}