from locust import HttpUser, task, between


class ShopUser(HttpUser):
    wait_time = between(0.5, 2.0)

    @task(3)
    def shop(self):
        self.client.get("/shop")

    @task(2)
    def homepage(self):
        self.client.get("/")

    @task(2)
    def stone_store(self):
        self.client.get("/kamenna-predajna")

    @task(2)
    def supplements_category(self):
        self.client.get("/shop/category/vyzivove-doplnky-49")

    @task(1)
    def cart(self):
        self.client.get("/shop/cart")

    @task(1)
    def odoo(self):
        self.client.get("/odoo")

    @task(1)
    def shop_page(self):
        self.client.get("/shop/page/1")
